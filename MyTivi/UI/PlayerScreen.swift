import SwiftUI

/// Xem kênh toàn màn hình (Siri Remote).
///  ▲ : kênh kế tiếp            ▼ : kênh trước đó
///  OK / ◄ ► : mở danh sách kênh
///  ▶︎❙❙ : hiện lại thanh thông tin
///  Giữ OK : thêm/bỏ yêu thích
///  Back (‹ / MENU) : đóng danh sách, hoặc quay về màn hình chính
/// Thanh thông tin (kênh, chương trình, thông số video) tự hiện vài giây khi vào kênh rồi ẩn.
struct PlayerScreen: View {
    let list: [Channel]
    @ObservedObject var store: Store
    @ObservedObject var engine: PlayerEngine
    let onClose: () -> Void

    enum Focus: Hashable { case root, item(Int) }

    @StateObject private var clock = Clock()
    @State private var index: Int
    @State private var showList = false
    @State private var showInfo = true
    @State private var infoTick = 0
    @FocusState private var focus: Focus?

    init(list: [Channel], startIndex: Int, store: Store, engine: PlayerEngine, onClose: @escaping () -> Void) {
        self.list = list
        self._store = ObservedObject(wrappedValue: store)
        self._engine = ObservedObject(wrappedValue: engine)
        self.onClose = onClose
        self._index = State(initialValue: min(max(startIndex, 0), max(list.count - 1, 0)))
    }

    private var current: Channel { list[index] }
    private var now: TimeInterval { clock.now }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoSurface(player: engine.player).ignoresSafeArea()

            // Vùng nhận phím remote (trong suốt, phủ toàn màn hình)
            Button(action: openList) {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(BareButtonStyle())
            .focusEffectDisabled()
            .focused($focus, equals: .root)
            .disabled(showList)
            .ignoresSafeArea()
            .onMoveCommand { dir in
                switch dir {
                case .up: move(1)
                case .down: move(-1)
                case .left, .right: openList()
                @unknown default: break
                }
            }
            .onPlayPauseCommand { infoTick += 1 }
            .contextMenu {
                Button(store.isFavorite(current) ? "Bỏ khỏi yêu thích" : "Thêm vào yêu thích") {
                    store.toggleFavorite(current)
                    infoTick += 1
                }
                Button("Hiện thông tin") { infoTick += 1 }
            }

            if engine.buffering && engine.error == nil {
                ProgressView().scaleEffect(1.5)
            }
            if let e = engine.error {
                Text("\(e)\nĐang thử lại…")
                    .multilineTextAlignment(.center)
                    .font(.system(size: 30))
                    .foregroundStyle(Theme.error)
                    .padding(36)
                    .background(RoundedRectangle(cornerRadius: 20).fill(Color.black.opacity(0.8)))
            }

            if showInfo && !showList {
                InfoBar(
                    ch: current,
                    number: index + 1,
                    favorite: store.isFavorite(current),
                    now: now,
                    nowProg: store.epg.nowPlaying(current, at: now),
                    nextProg: store.epg.nextPlaying(current, at: now),
                    stream: engine.info
                )
                .frame(maxHeight: .infinity, alignment: .bottom)
                .transition(.opacity.combined(with: .offset(y: 60)))
            }

            if showList {
                channelPanel
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.35), value: showInfo)
        .animation(.easeOut(duration: 0.2), value: showList)
        .onExitCommand {
            if showList { closeList() } else { onClose() }
        }
        .onAppear { focus = .root }
        // Đổi kênh: chờ 250ms để bấm liên tục không làm server bị gọi dồn dập
        .task(id: index) {
            let ch = current
            infoTick += 1
            if engine.currentURL != ch.url {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { return }
                engine.play(ch.url)
            }
            store.lastChannelUrl = ch.url
        }
        // Thanh thông tin hiện 5 giây rồi ẩn
        .task(id: infoTick) {
            showInfo = true
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled { showInfo = false }
        }
        // Đọc được thông số luồng (thường sau 1-2 giây) thì hiện lại thanh thông tin cho đủ thời gian xem
        .onChange(of: engine.info != nil) { _, has in
            if has { infoTick += 1 }
        }
    }

    private func move(_ step: Int) {
        guard !list.isEmpty else { return }
        index = (index + step + list.count) % list.count
    }

    private func openList() {
        showList = true
    }

    private func closeList() {
        showList = false
        DispatchQueue.main.async { focus = .root }
    }

    // MARK: - Bảng chọn kênh

    private var channelPanel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(list.indices, id: \.self) { i in
                        channelItem(i, proxy: proxy)
                    }
                }
                .padding(.vertical, 20)
                .padding(.horizontal, 16)
            }
            .onAppear {
                proxy.scrollTo(index, anchor: .center)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focus = .item(index) }
            }
        }
        .frame(width: 760)
        .frame(maxHeight: .infinity)
        .background(Color(hex: 0x0B1220, alpha: 0.93).ignoresSafeArea())
        .focusSection()
    }

    private func channelItem(_ i: Int, proxy: ScrollViewProxy) -> some View {
        let ch = list[i]
        return Button {
            index = i
            closeList()
        } label: {
            HStack(spacing: 16) {
                Text("\(i + 1)")
                    .foregroundStyle(Theme.dim)
                    .frame(width: 80, alignment: .leading)
                LogoView(url: ch.logo, size: 50)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ch.name)
                        .foregroundStyle(i == index ? Theme.accent : Color.white)
                        .lineLimit(1)
                    if let p = store.epg.nowPlaying(ch, at: now) {
                        Text(p.title)
                            .font(.system(size: 22))
                            .foregroundStyle(Theme.dim)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if store.isFavorite(ch) {
                    Text("★").foregroundStyle(Theme.gold)
                }
            }
            .font(.system(size: 28))
        }
        .buttonStyle(TvRowButtonStyle(padding: EdgeInsets(top: 10, leading: 18, bottom: 10, trailing: 18)))
        .focused($focus, equals: .item(i))
        .id(i)
        // Cuộn vòng: ở kênh đầu bấm ▲ -> kênh cuối; ở kênh cuối bấm ▼ -> kênh đầu
        .onMoveCommand { dir in
            if dir == .up && i == 0 {
                jump(to: list.count - 1, proxy: proxy)
            } else if dir == .down && i == list.count - 1 {
                jump(to: 0, proxy: proxy)
            }
        }
        .contextMenu {
            Button(store.isFavorite(ch) ? "Bỏ khỏi yêu thích" : "Thêm vào yêu thích") {
                store.toggleFavorite(ch)
            }
        }
    }

    private func jump(to i: Int, proxy: ScrollViewProxy) {
        proxy.scrollTo(i, anchor: .center)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focus = .item(i) }
    }
}

/// Thanh thông tin ở cạnh dưới khi xem kênh
private struct InfoBar: View {
    let ch: Channel
    let number: Int
    let favorite: Bool
    let now: TimeInterval
    let nowProg: Programme?
    let nextProg: Programme?
    let stream: StreamInfo?

    var body: some View {
        HStack(alignment: .center, spacing: 32) {
            Text("\(number)")
                .font(.system(size: 64, weight: .semibold))
                .foregroundStyle(Theme.accent)
            LogoView(url: ch.logo, size: 120)
            VStack(alignment: .leading, spacing: 8) {
                Text(ch.name + (favorite ? "  ★" : ""))
                    .font(.system(size: 42, weight: .semibold))
                    .lineLimit(1)
                if let p = nowProg {
                    Text("\(Fmt.hhmm(p.start)) – \(Fmt.hhmm(p.stop))   \(p.title)")
                        .font(.system(size: 30))
                        .lineLimit(1)
                    ProgressLine(value: p.progress(at: now), height: 8)
                        .frame(maxWidth: 900)
                        .padding(.vertical, 6)
                }
                if let n = nextProg {
                    Text("Tiếp theo: \(Fmt.hhmm(n.start))  \(n.title)")
                        .font(.system(size: 26))
                        .foregroundStyle(Theme.dim)
                        .lineLimit(1)
                }
                if let stream {
                    StreamBadges(info: stream).padding(.top, 8)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                Text(Fmt.hhmm(now))
                    .font(.system(size: 64, weight: .light))
                Text(Fmt.longDay(now))
                    .font(.system(size: 24))
                    .foregroundStyle(Theme.dim)
            }
        }
        .padding(.horizontal, 90)
        .padding(.top, 110)
        .padding(.bottom, 60)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: Color(hex: 0x070D18, alpha: 0.85), location: 0.35),
                    .init(color: Color(hex: 0x070D18, alpha: 0.95), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .ignoresSafeArea()
    }
}
