#!/usr/bin/env bash
# =============================================================================
#  Tạo LXC "atvloadly" trên Proxmox để cài MyTivi lên Apple TV và tự gia hạn.
#
#  Chạy trên Proxmox host (tab Shell của node, quyền root):
#      bash proxmox-atvloadly.sh
#
#  Khi chạy, script hỏi VLAN và mật khẩu root của LXC.
#  Có thể đặt sẵn bằng biến môi trường để khỏi hỏi, ví dụ:
#      VLAN=30 ROOT_PW='MatKhau123' bash proxmox-atvloadly.sh
#      CTID=150 BRIDGE=vmbr1 STORAGE=local-zfs VLAN=none bash proxmox-atvloadly.sh
#
#  Script sẽ:
#   1. Tải template Debian 12 (nếu chưa có)
#   2. Tạo LXC privileged, bật nesting, mạng DHCP trên bridge cùng LAN với Apple TV
#   3. Cài Docker + Avahi trong LXC
#   4. Chạy container atvloadly (giao diện web ở cổng 5533)
# =============================================================================
set -euo pipefail

# ---------------- Thông số (đổi được qua biến môi trường) ----------------
CTID="${CTID:-}"                       # để trống = lấy ID trống tiếp theo
CT_HOSTNAME="${CT_HOSTNAME:-atvloadly}"
BRIDGE="${BRIDGE:-vmbr0}"              # bridge phải cùng mạng LAN với Apple TV
VLAN="${VLAN:-}"                       # VLAN tag (vd 30); "none" = không dùng VLAN; trống = hỏi
ROOT_PW="${ROOT_PW:-}"                 # mật khẩu root của LXC; trống = hỏi
STORAGE="${STORAGE:-}"                 # nơi chứa ổ đĩa LXC; trống = tự chọn
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
DISK_GB="${DISK_GB:-8}"
MEMORY_MB="${MEMORY_MB:-1024}"
CORES="${CORES:-1}"
WEB_PORT="${WEB_PORT:-5533}"
IMAGE="${IMAGE:-bitxeno/atvloadly:latest}"

GREEN='\033[1;32m'; YELLOW='\033[1;33m'; RED='\033[1;31m'; NC='\033[0m'
info() { echo -e "${GREEN}==>${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[X]${NC} $*" >&2; exit 1; }

# ---------------- Kiểm tra môi trường ----------------
[ "$(id -u)" -eq 0 ] || die "Hãy chạy bằng root trên Proxmox host."
command -v pct >/dev/null && command -v pveam >/dev/null \
  || die "Không thấy lệnh pct/pveam. Script này phải chạy trên Proxmox host (không phải trong VM/LXC)."
ip link show "$BRIDGE" >/dev/null 2>&1 || die "Không có bridge '$BRIDGE'. Đặt BRIDGE=<tên bridge> rồi chạy lại."

if [ -z "$CTID" ]; then
  CTID="$(pvesh get /cluster/nextid)"
fi
pct status "$CTID" >/dev/null 2>&1 && die "CT $CTID đã tồn tại. Đặt CTID=<số khác> rồi chạy lại."

if [ -z "$STORAGE" ]; then
  # Ưu tiên local-lvm, sau đó local-zfs, sau đó storage đầu tiên hỗ trợ rootdir
  for s in local-lvm local-zfs; do
    if pvesm status -content rootdir 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$s"; then STORAGE="$s"; break; fi
  done
  [ -n "$STORAGE" ] || STORAGE="$(pvesm status -content rootdir | awk 'NR==2{print $1}' || true)"
  [ -n "$STORAGE" ] || die "Không tìm thấy storage cho LXC. Đặt STORAGE=<tên storage> rồi chạy lại."
fi

# ---------------- Hỏi VLAN và mật khẩu ----------------
if [ -z "$VLAN" ]; then
  if [ -t 0 ]; then
    read -r -p "VLAN tag cho LXC (cùng VLAN với Apple TV, vd 30; Enter = không dùng VLAN): " VLAN
  fi
  VLAN="${VLAN:-none}"
fi
if [ "$VLAN" != "none" ]; then
  [[ "$VLAN" =~ ^[0-9]+$ ]] && [ "$VLAN" -ge 1 ] && [ "$VLAN" -le 4094 ] || die "VLAN '$VLAN' không hợp lệ (1-4094)."
fi

PW_SHOWN=0
if [ -z "$ROOT_PW" ]; then
  if [ -t 0 ]; then
    while true; do
      read -r -s -p "Mật khẩu root cho LXC (Enter = tạo ngẫu nhiên): " p1; echo
      if [ -z "$p1" ]; then break; fi
      read -r -s -p "Nhập lại mật khẩu: " p2; echo
      if [ "$p1" != "$p2" ]; then warn "Hai lần nhập không khớp, nhập lại."; continue; fi
      if [ "${#p1}" -lt 5 ]; then warn "Mật khẩu phải từ 5 ký tự, nhập lại."; continue; fi
      ROOT_PW="$p1"; break
    done
  fi
  if [ -z "$ROOT_PW" ]; then ROOT_PW="$(openssl rand -hex 8)"; PW_SHOWN=1; fi
fi
[ "${#ROOT_PW}" -ge 5 ] || die "Mật khẩu root phải từ 5 ký tự."

NET0="name=eth0,bridge=${BRIDGE},ip=dhcp"
[ "$VLAN" != "none" ] && NET0="${NET0},tag=${VLAN}"

info "CT ID: $CTID | hostname: $CT_HOSTNAME | bridge: $BRIDGE | VLAN: $VLAN | storage: $STORAGE | disk: ${DISK_GB}G | RAM: ${MEMORY_MB}MB"

# ---------------- 1. Template Debian 12 ----------------
info "Cập nhật danh sách template..."
pveam update >/dev/null || warn "pveam update lỗi, dùng danh sách cũ."
TEMPLATE="$(pveam available --section system | awk '{print $2}' | grep -E '^debian-12-standard_.*amd64' | sort -V | tail -n1 || true)"
[ -n "$TEMPLATE" ] || die "Không tìm thấy template debian-12-standard."
if ! pveam list "$TEMPLATE_STORAGE" | grep -q "$TEMPLATE"; then
  info "Tải template $TEMPLATE..."
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
fi

# ---------------- 2. Tạo LXC ----------------
info "Tạo LXC $CTID..."
pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
  --hostname "$CT_HOSTNAME" \
  --cores "$CORES" \
  --memory "$MEMORY_MB" \
  --swap 512 \
  --rootfs "${STORAGE}:${DISK_GB}" \
  --net0 "$NET0" \
  --unprivileged 0 \
  --features "nesting=1" \
  --onboot 1 \
  --ostype debian \
  --password "$ROOT_PW" \
  --description "atvloadly – cài MyTivi lên Apple TV và tự gia hạn. Web: http://<IP>:${WEB_PORT}"

# Docker trong LXC cần bỏ giới hạn AppArmor
cat >> "/etc/pve/lxc/${CTID}.conf" <<EOF
lxc.apparmor.profile: unconfined
lxc.cgroup2.devices.allow: a
lxc.cap.drop:
EOF

info "Khởi động LXC..."
pct start "$CTID"

info "Chờ LXC có mạng..."
for i in $(seq 1 60); do
  if pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1; then break; fi
  sleep 2
  [ "$i" -eq 60 ] && die "LXC chưa có mạng sau 2 phút. Kiểm tra DHCP trên bridge $BRIDGE (VLAN: $VLAN) và cổng switch có cho VLAN này đi qua không."
done

# ---------------- 3 + 4. Cài Docker, Avahi, atvloadly ----------------
info "Cài Docker + Avahi + atvloadly trong LXC (mất vài phút)..."
pct exec "$CTID" -- env WEB_PORT="$WEB_PORT" IMAGE="$IMAGE" bash -euo pipefail -c '
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl dbus avahi-daemon docker.io >/dev/null

# Avahi trong container: bỏ giới hạn số tiến trình (hay làm avahi không chạy trong LXC)
sed -i "s/^rlimit-nproc/#rlimit-nproc/" /etc/avahi/avahi-daemon.conf || true
systemctl start dbus || true
systemctl enable --now docker avahi-daemon
systemctl restart avahi-daemon

mkdir -p /etc/atvloadly

# Script cập nhật atvloadly lên bản mới: chạy "atvloadly-update" trong LXC
cat > /usr/local/bin/atvloadly-update <<EOS
#!/usr/bin/env bash
set -e
docker pull ${IMAGE}
docker rm -f atvloadly >/dev/null 2>&1 || true
docker run -d --name=atvloadly --restart=always --privileged \\
  -p ${WEB_PORT}:80 \\
  -v /etc/atvloadly:/data \\
  -v /var/run/dbus:/var/run/dbus \\
  -v /var/run/avahi-daemon:/var/run/avahi-daemon \\
  ${IMAGE}
docker image prune -f >/dev/null
echo "atvloadly đã chạy bản mới nhất."
EOS
chmod +x /usr/local/bin/atvloadly-update
/usr/local/bin/atvloadly-update
'

# ---------------- Kiểm tra ----------------
sleep 5
CT_IP="$(pct exec "$CTID" -- hostname -I | awk '{print $1}')"
if pct exec "$CTID" -- curl -fsS -o /dev/null "http://127.0.0.1:${WEB_PORT}"; then
  WEB_OK="${GREEN}đang chạy${NC}"
else
  WEB_OK="${YELLOW}chưa trả lời (đợi thêm 1 phút rồi mở thử)${NC}"
fi
AVAHI_OK="$(pct exec "$CTID" -- systemctl is-active avahi-daemon || true)"

echo
echo -e "${GREEN}================== XONG ==================${NC}"
echo -e " LXC ID         : $CTID ($CT_HOSTNAME)"
if [ "$PW_SHOWN" -eq 1 ]; then
  echo -e " Mật khẩu root  : $ROOT_PW   (ngẫu nhiên — hãy lưu lại)"
else
  echo -e " Mật khẩu root  : (mật khẩu bạn đã nhập)"
fi
echo -e " Mạng           : $BRIDGE, VLAN $VLAN, DHCP"
echo -e " Avahi          : $AVAHI_OK"
echo -e " atvloadly      : $WEB_OK"
echo -e " Giao diện web  : ${GREEN}http://${CT_IP}:${WEB_PORT}${NC}"
echo
echo " Bước tiếp theo:"
echo "  1. Trên Apple TV: Cài đặt > Điều khiển từ xa và thiết bị > Ứng dụng và thiết bị điều khiển từ xa"
echo "  2. Mở http://${CT_IP}:${WEB_PORT}, bấm vào Apple TV, nhập mã hiện trên TV"
echo "  3. Đăng nhập Apple ID (nên dùng Apple ID riêng), chọn MyTivi.ipa, bấm Install"
echo "     Tải MyTivi.ipa: https://github.com/xuanthanhtnt/MyTivi-tvOS/releases/latest/download/MyTivi.ipa"
echo
echo " Cập nhật atvloadly sau này: pct exec $CTID -- atvloadly-update"
echo -e "${GREEN}==========================================${NC}"
