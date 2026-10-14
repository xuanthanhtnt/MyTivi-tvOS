# MyTivi cho Apple TV (tvOS)

Bản viết lại của app MyTivi (Android TV) cho **Apple TV**, bằng Swift + SwiftUI + AVPlayer.
Giữ nguyên giao diện kiểu TiviMate và cách dùng của bản Android, đổi phím cho hợp với Siri Remote.

## Yêu cầu
- **Máy Mac** có **Xcode 16 trở lên** (tải miễn phí trên App Store). Không có Mac thì không cài được app lên Apple TV.
- **Apple ID** (miễn phí) hoặc tài khoản **Apple Developer** (99 USD/năm).
- Apple TV HD hoặc Apple TV 4K, chạy **tvOS 17 trở lên**.

## Tính năng (giống bản Android)
- Playlist M3U / một luồng .m3u8, nhóm kênh (group-title), logo, tìm kiếm, kênh yêu thích
- EPG XMLTV (hỗ trợ .gz): chương trình đang phát, thanh tiến độ, chương trình tiếp theo
- Màn hình chính kiểu TiviMate: khung xem trước bo góc (**có tiếng**) + thông tin chương trình;
  thanh thời gian có mũi tên "bây giờ"; bảng kênh/chương trình 12 giờ, các hàng trượt ngang cùng nhau
- Ngăn nhóm kênh ẩn bên trái: tìm kiếm, danh sách nhóm (lướt tới nhóm nào danh sách kênh đổi theo), Làm mới, Cài đặt, phiên bản
- Cuộn vòng danh sách kênh (cuối ↔ đầu) ở cả bảng lịch và bảng chọn kênh toàn màn hình
- Xem toàn màn hình: thanh thông tin tự hiện ~5 giây khi vào kênh: số kênh, logo, chương trình, đồng hồ,
  thông số luồng (SD/HD/FHD/4K, độ phân giải, fps, codec hình, âm thanh, bitrate)
- Tự tải lại playlist mỗi 3 giờ, EPG mỗi 6 giờ; có cache nên mở app là có kênh và lịch ngay
- Mở app là vào thẳng kênh xem gần nhất; mất luồng tự thử lại sau 5 giây
- Bấm Home / tắt TV thì tự dừng tiếng; quay lại thì phát tiếp từ điểm trực tiếp
- **Mới so với bản Android:** vào toàn màn hình từ khung xem trước thì kênh chạy tiếp ngay, không phải tải lại;
  hỗ trợ link dạng `url|User-Agent=...&Referer=...`

## Điều khiển bằng Siri Remote

### Màn hình chính (bảng lịch)
| Phím | Việc |
|---|---|
| ▲ ▼ | Chọn kênh (cuộn vòng) |
| ◄ ► | Đi giữa cột tên kênh, ☆ và các ô chương trình |
| ◄ ở cột tên kênh | Mở ngăn nhóm kênh |
| OK (bấm giữa) | Xem toàn màn hình (ở cột ☆: thêm/bỏ yêu thích) |
| ▶︎❙❙ (Play/Pause) | Thêm/bỏ yêu thích kênh đang chọn |
| ‹ / MENU (Back) | Đóng ngăn nhóm kênh; ở màn hình chính thì về Home |

### Ngăn nhóm kênh
- ▲ ▼ chọn nhóm (danh sách kênh đổi theo ngay), **►** hoặc **OK** hoặc **Back** để quay lại bảng kênh.
- Ô **Tìm kênh…** ở trên cùng; **Làm mới**, **Cài đặt** ở dưới cùng.

### Xem toàn màn hình
| Phím | Việc |
|---|---|
| ▲ / ▼ | Kênh kế tiếp / kênh trước đó |
| OK hoặc ◄ ► | Mở danh sách kênh |
| ▶︎❙❙ | Hiện lại thanh thông tin |
| Giữ OK | Menu thêm/bỏ yêu thích |
| Back | Đóng danh sách, hoặc quay về màn hình chính |

## Cách build và cài lên Apple TV
1. Mở `MyTivi.xcodeproj` bằng Xcode.
2. **Ghép Apple TV với Xcode** (làm một lần):
   - Mac và Apple TV cùng mạng Wi-Fi/LAN.
   - Trên Apple TV: *Cài đặt > Điều khiển từ xa và thiết bị > Ứng dụng và thiết bị điều khiển từ xa* (Remote App and Devices).
   - Trên Mac: Xcode > menu *Window > Devices and Simulators* → Apple TV hiện ra → *Pair* → nhập mã hiện trên TV.
3. Chọn target **MyTivi** > tab **Signing & Capabilities** > **Team**: chọn Apple ID của bạn
   (chưa có thì *Add an Account…*).
   - Nếu báo trùng *Bundle Identifier*, đổi `com.xuanthanhtnt.mytivi` thành tên khác, ví dụ `com.tencuaban.mytivi`.
4. Trên thanh công cụ Xcode chọn thiết bị là Apple TV của bạn, bấm **▶ Run** (⌘R).
5. Muốn chạy thử không cần Apple TV: chọn thiết bị **Apple TV Simulator** rồi bấm Run
   (trên simulator, phím mũi tên trên bàn phím Mac = vuốt trên remote, Enter = OK, Esc = Back).

### Thời hạn của bản cài
- **Apple ID miễn phí:** app hết hạn sau **7 ngày**, phải cắm lại Xcode bấm Run để gia hạn.
- **Tài khoản Apple Developer (trả phí):** app dùng được 1 năm; có thể đưa lên **TestFlight**
  (Xcode > *Product > Archive* > *Distribute App* > *TestFlight*). Cài app TestFlight trên Apple TV,
  mỗi lần bạn đẩy bản mới, Apple TV **tự cập nhật** — thay cho tính năng tự cập nhật APK của bản Android
  (tvOS không cho app tự tải và cài bản cập nhật).

### Kiểm tra build trên GitHub (không cần Mac)
File `.github/workflows/build-tvos.yml` build thử app trên máy macOS của GitHub mỗi lần push.
Tải toàn bộ thư mục này (cả thư mục ẩn `.github`) lên một repo, vào tab **Actions** xem kết quả.
Bản build này không ký nên **không cài được** lên Apple TV — chỉ để biết mã nguồn có build được không.

## Khác biệt so với bản Android
| | Android | Apple TV |
|---|---|---|
| Trình phát | ExoPlayer (Media3) | AVPlayer |
| Định dạng luồng | HLS, DASH, TS, MP4… | **HLS (.m3u8), MP4, MOV**. Luồng **MPEG-TS trần (.ts qua HTTP), RTMP, RTSP, UDP không phát được** |
| Tự cập nhật | Tải APK từ GitHub Releases | Không cho phép trên tvOS → dùng TestFlight |
| Phím CH+/CH-, INFO, MENU | Có | Siri Remote không có → ▲▼, ▶︎❙❙, giữ OK |
| Bộ nhớ | Thư mục app | Thư mục Caches (tvOS có thể xóa khi đầy; app tự tải lại) |

Nếu playlist của bạn nhiều kênh dạng `.ts`, bước tiếp theo nên làm là thêm thư viện **TVVLCKit**
(VLC cho tvOS, cài qua Swift Package Manager / CocoaPods) và thay `PlayerEngine` bằng trình phát VLC.

## Cấu trúc mã
| File | Việc |
|---|---|
| `App/MyTiviApp.swift` | Điểm vào app; chuyển giữa Màn hình chính / Toàn màn hình / Cài đặt; dừng tiếng khi xuống nền |
| `Data/Models.swift` | Kênh, chương trình, tra chương trình đang phát / tiếp theo |
| `Data/M3UParser.swift` | Đọc #EXTINF (tvg-id, tvg-logo, group-title…), link có header `url\|User-Agent=…` |
| `Data/EPGParser.swift` | Đọc XMLTV (luồng, ít tốn RAM), chỉ giữ -2h..+24h |
| `Data/Gzip.swift` | Giải nén EPG .gz |
| `Data/Http.swift` | Tải playlist/EPG (URLSession) |
| `Data/Store.swift` | Trạng thái chung: kênh, yêu thích, EPG, cache, tự cập nhật (tương đương `MainViewModel.kt`) |
| `Data/Prefs.swift` | Lưu cài đặt (UserDefaults) |
| `Data/Guide.swift` | Chia EPG thành các ô trên bảng lịch |
| `Player/PlayerEngine.swift` | AVPlayer dùng chung (xem trước 480p + toàn màn hình), tự thử lại, lớp hiển thị video |
| `Player/StreamInfo.swift` | Thông số luồng cho thanh thông tin |
| `UI/BrowseScreen.swift` | Màn hình chính: xem trước + bảng lịch + ngăn nhóm kênh |
| `UI/PlayerScreen.swift` | Toàn màn hình, thanh thông tin, bảng chọn kênh |
| `UI/SetupScreen.swift` | Nhập link playlist / EPG |
| `UI/Theme.swift`, `UI/LogoView.swift` | Màu, kiểu nút, đồng hồ, bộ nhớ đệm logo |

## Chỉnh nhanh
- Tần suất tự cập nhật: đầu file `Store.swift` (`playlistTTL`, `epgTTL`, `checkEvery`).
- Kích thước bảng lịch: đầu file `BrowseScreen.swift` (`leftW`, `rowH`, `ptPerMin`, `guideHours`, `topH`).
- Icon và ảnh Top Shelf: `MyTivi/Assets.xcassets/App Icon & Top Shelf Image.brandassets`
  (icon tvOS có 3 lớp Front/Middle/Back để tạo hiệu ứng nổi khi chọn).

## Hạn chế hiện tại
- EPG ghép theo `tvg-id`; kênh không có tvg-id hiện "Không có thông tin".
- Chưa có: nhập số kênh, ghi hình, catch-up, multiview, khóa phụ huynh, Xtream Codes, nhiều playlist.

Chỉ dùng với nội dung bạn có quyền xem.
