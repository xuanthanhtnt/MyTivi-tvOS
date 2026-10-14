import SwiftUI

/// Màn hình chính kiểu TiviMate: khung xem trước + thông tin chương trình ở trên,
/// thanh thời gian và bảng kênh/chương trình ở dưới, ngăn nhóm kênh ẩn bên trái.
///
/// Bảng lịch là MỘT vùng nhận focus duy nhất; ô đang chọn do app tự quản lý (hàng + cột + mốc giờ).
/// Nhờ vậy điều khiển bằng Siri Remote giống hệt bản Android: cuộn vòng, các hàng cùng trượt ngang,
/// ◄ ở cột tên kênh mở ngăn nhóm kênh.
struct BrowseScreen: View {
    @ObservedObject var store: Store
    @ObservedObject var engine: PlayerEngine
    let isActive: Bool
    let onPlay: ([Channel], Int) -> Void
    let onSettings: () -> Void

    // ---- Kích thước bảng lịch (chỉnh ở đây nếu muốn) ----
    static let leftW: CGFloat = 600        // cột số kênh + logo + tên
    static let starW: CGFloat = 80         // cột ☆
    static let rowH: CGFloat = 92          // chiều cao mỗi hàng kênh
    static let ptPerMin: CGFloat = 12      // 30 phút = 360 điểm
    static let guideHours = 12             // bảng lịch hiển thị 12 giờ kể từ bây giờ
    static let topH: CGFloat = 320         // chiều cao khung xem trước

    enum Column { case header, star, cell }
    enum Focus: Hashable { case guide, search, group(Int), refresh, settings }

    @StateObject private var clock = Clock()

    @State private var sel = 1                 // 0 = Yêu thích, 1 = Tất cả, 2.. = nhóm
    @State private var query = ""
    @State private var showDrawer = false
    @State private var groups: [String] = []
    @State private var counts: [Int] = []
    @State private var shown: [Channel] = []

    @State private var row = 0
    @State private var topRow = 0
    @State private var col: Column = .header
    @State private var selTime: TimeInterval = 0
    @State private var hOffsetMin: Double = 0  // số phút đã cuộn ngang tính từ đầu bảng lịch
    @State private var visibleRows = 5
    @State private var cellAreaW: CGFloat = 1000

    @FocusState private var focus: Focus?

    private var labels: [String] { ["★ Yêu thích", "Tất cả"] + groups }
    private var now: TimeInterval { clock.now }
    /// Mốc đầu bảng lịch tự dời theo mỗi nửa giờ (để Apple TV mở cả ngày vẫn đúng giờ)
    private var windowStart: TimeInterval { floorTo(now, TimeConst.halfHour) }
    private var windowEnd: TimeInterval { windowStart + Double(Self.guideHours) * TimeConst.hour }
    private var totalMin: Double { Double(Self.guideHours * 60) }
    private var visibleMin: Double { Double(cellAreaW / Self.ptPerMin) }
    private var focusedChannel: Channel? { shown.indices.contains(row) ? shown[row] : nil }

    private var focusedProg: Programme? {
        guard let ch = focusedChannel else { return nil }
        if col == .cell {
            let cells = cellsFor(ch)
            return selectedCellIndex(cells).flatMap { cells[$0].programme }
        }
        return store.epg.nowPlaying(ch, at: now)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            VStack(alignment: .leading, spacing: 0) {
                topSection
                    .frame(height: Self.topH)
                Spacer().frame(height: 18)
                timeline
                Rectangle().fill(Theme.line).frame(height: 2)
                guideArea
            }
            .opacity(showDrawer ? 0.55 : 1)

            if showDrawer {
                drawer
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: showDrawer)
        .onAppear {
            recompute()
            restoreRow()
            focusGuideSoon()
        }
        .onChange(of: store.revision) { recompute() }
        .onChange(of: store.favorites) { recompute() }
        .onChange(of: sel) { recompute() }
        .onChange(of: query) { recompute() }
        .onChange(of: isActive) { _, active in
            if active {
                restoreRow()
                focusGuideSoon()
            }
        }
        .onChange(of: focus) { _, f in
            // Di chuyển tới nhóm nào trong ngăn, danh sách kênh đổi theo nhóm đó
            if case .group(let i)? = f, i != sel { sel = i }
        }
        .task(id: PreviewKey(url: focusedChannel?.url, active: isActive)) {
            await updatePreview()
        }
    }

    // MARK: - Dữ liệu

    private func recompute() {
        let keepURL = focusedChannel?.url
        let channels = store.channels
        let favs = store.favorites
        var order: [String] = []
        var byGroup: [String: Int] = [:]
        for ch in channels {
            if byGroup[ch.group] == nil { order.append(ch.group) }
            byGroup[ch.group, default: 0] += 1
        }
        groups = order
        counts = [channels.filter { favs.contains($0.url) }.count, channels.count] + order.map { byGroup[$0] ?? 0 }
        let current = sel < order.count + 2 ? sel : 1
        if current != sel { sel = current }

        let base: [Channel]
        switch current {
        case 0: base = channels.filter { favs.contains($0.url) }
        case 1: base = channels
        default:
            let g = order[current - 2]
            base = channels.filter { $0.group == g }
        }
        let q = query.trimmingCharacters(in: .whitespaces)
        shown = q.isEmpty ? base : base.filter { $0.name.localizedCaseInsensitiveContains(q) }

        var idx = keepURL.flatMap { u in shown.firstIndex { $0.url == u } }
        if idx == nil { idx = shown.firstIndex { $0.url == store.lastChannelUrl } }
        setRow(idx ?? 0)
    }

    /// Quay lại từ toàn màn hình: chọn đúng kênh vừa xem
    private func restoreRow() {
        if let i = shown.firstIndex(where: { $0.url == store.lastChannelUrl }) { setRow(i) }
        col = .header
        hOffsetMin = 0
    }

    private func setRow(_ i: Int) {
        let n = shown.count
        guard n > 0 else {
            row = 0
            topRow = 0
            return
        }
        row = min(max(i, 0), n - 1)
        // Kênh được chọn nằm ngoài phần nhìn thấy thì đưa nó về khoảng giữa
        if row < topRow || row >= topRow + visibleRows {
            topRow = row - visibleRows / 2
        }
        topRow = max(0, min(topRow, n - visibleRows))
    }

    private func cellsFor(_ ch: Channel) -> [GuideCell] {
        buildCells(store.epg.programmes(for: ch), from: windowStart, to: windowEnd)
    }

    private func selectedCellIndex(_ cells: [GuideCell]) -> Int? {
        guard !cells.isEmpty else { return nil }
        let t = max(selTime, windowStart)
        return cells.firstIndex { $0.contains(t) } ?? cells.count - 1
    }

    // MARK: - Điều khiển bằng remote

    private func move(_ dir: MoveCommandDirection) {
        guard !showDrawer else { return }
        guard !shown.isEmpty else {
            if dir == .left { openDrawer() }
            return
        }
        switch dir {
        case .up: moveRow(-1)
        case .down: moveRow(1)
        case .left:
            switch col {
            case .header:
                openDrawer()          // ◄ ở cột tên kênh -> mở ngăn nhóm kênh
            case .star:
                col = .header
            case .cell:
                let cells = cellsFor(shown[row])
                if let k = selectedCellIndex(cells), k > 0 {
                    selTime = cells[k - 1].start
                    scrollToShow(cells[k - 1])
                } else {
                    col = .star
                    withAnimation(.easeOut(duration: 0.2)) { hOffsetMin = 0 }
                }
            }
        case .right:
            switch col {
            case .header:
                col = .star
            case .star:
                col = .cell
                selTime = max(now, windowStart + hOffsetMin * 60)
                let cells = cellsFor(shown[row])
                if let k = selectedCellIndex(cells) { scrollToShow(cells[k]) }
            case .cell:
                let cells = cellsFor(shown[row])
                if let k = selectedCellIndex(cells), k + 1 < cells.count {
                    selTime = cells[k + 1].start
                    scrollToShow(cells[k + 1])
                }
            }
        @unknown default:
            break
        }
    }

    /// Cuộn vòng: ở kênh cuối bấm ▼ về kênh đầu, ở kênh đầu bấm ▲ xuống kênh cuối
    private func moveRow(_ d: Int) {
        let n = shown.count
        guard n > 0 else { return }
        row = (row + d + n) % n
        if row < topRow {
            topRow = row
        } else if row >= topRow + visibleRows {
            topRow = row - visibleRows + 1
        }
        topRow = max(0, min(topRow, max(0, n - visibleRows)))
    }

    private func scrollToShow(_ c: GuideCell) {
        let startMin = (c.start - windowStart) / 60
        let endMin = (c.end - windowStart) / 60
        var off = hOffsetMin
        if startMin < off {
            off = startMin
        } else if endMin > off + visibleMin {
            off = min(startMin, endMin - visibleMin)
        }
        off = max(0, min(off, max(0, totalMin - visibleMin)))
        if off != hOffsetMin {
            withAnimation(.easeOut(duration: 0.2)) { hOffsetMin = off }
        }
    }

    /// OK trên bảng lịch: ☆ thì thêm/bỏ yêu thích, còn lại xem toàn màn hình
    private func activate() {
        guard let ch = focusedChannel else {
            openDrawer()
            return
        }
        if col == .star {
            store.toggleFavorite(ch)
        } else {
            onPlay(shown, row)
        }
    }

    private func openDrawer() {
        guard !showDrawer else { return }
        showDrawer = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focus = .group(sel) }
    }

    private func closeDrawer() {
        guard showDrawer else { return }
        showDrawer = false
        focusGuideSoon()
    }

    private func focusGuideSoon() {
        DispatchQueue.main.async { focus = .guide }
    }

    private func updatePreview() async {
        guard isActive else { return }
        guard let url = focusedChannel?.url else {
            engine.stop()
            return
        }
        if engine.currentURL == url { return }
        // Chờ một nhịp ngắn: khi vừa quay lại từ toàn màn hình, hàng được chọn còn đang đổi
        try? await Task.sleep(nanoseconds: 60_000_000)
        if Task.isCancelled || engine.currentURL == url { return }
        engine.stop()
        try? await Task.sleep(nanoseconds: 640_000_000)     // lướt nhanh thì không tải từng kênh
        if Task.isCancelled { return }
        engine.play(url)
    }

    // MARK: - Phần trên: xem trước | thông tin

    private var topSection: some View {
        HStack(alignment: .top, spacing: 40) {
            previewBox
                .frame(width: Self.topH * 16 / 9, height: Self.topH)
            infoPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var previewBox: some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        return ZStack {
            Color.black
            if isActive { VideoSurface(player: engine.player) }
            if focusedChannel == nil {
                Text("Chọn một kênh để xem trước").foregroundStyle(Theme.dim)
            } else if engine.error != nil {
                Text("Không xem trước được kênh này").foregroundStyle(Theme.error)
            } else if engine.buffering {
                ProgressView()
            }
        }
        .font(.system(size: 26))
        .clipShape(shape)
        .overlay(shape.stroke(Color.white.opacity(0.25), lineWidth: 2))
    }

    private var infoPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let ch = focusedChannel {
                let prog = focusedProg
                Text(prog?.title ?? "Không có thông tin")
                    .font(.system(size: 44, weight: .bold))
                    .lineLimit(2)
                if let p = prog {
                    HStack(spacing: 24) {
                        Text("\(Fmt.hhmm(p.start)) – \(Fmt.hhmm(p.stop))")
                            .font(.system(size: 30))
                            .fixedSize()
                        if p.isLive(at: now) {
                            ProgressLine(value: p.progress(at: now))
                                .frame(width: 240)
                            Text("còn \(Int(((p.stop - now) / 60).rounded(.up))) phút")
                                .font(.system(size: 28))
                                .foregroundStyle(Theme.dim)
                                .fixedSize()
                        }
                    }
                }
                Text("\(row + 1). \(ch.name)")
                    .font(.system(size: 30))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("OK: Toàn màn hình     ◄: Nhóm kênh     ▶︎❙❙: Yêu thích")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
            } else {
                Text(store.loading ? "Đang tải danh sách kênh…" : "Lướt qua danh sách kênh để xem trước.")
                    .font(.system(size: 30))
                    .foregroundStyle(Theme.dim)
                if let e = store.error {
                    Text(e).font(.system(size: 26)).foregroundStyle(Theme.error)
                }
                Spacer(minLength: 0)
                Text("◄: Nhóm kênh, Làm mới, Cài đặt")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.dim)
            }
        }
        .padding(.top, 6)
    }

    // MARK: - Thanh thời gian

    private var timeline: some View {
        let nowX = CGFloat((now - windowStart) / 60) * Self.ptPerMin - CGFloat(hOffsetMin) * Self.ptPerMin
        return HStack(spacing: 0) {
            Text(Fmt.shortDay(now))
                .font(.system(size: 26))
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
                .padding(.leading, 16)
                .frame(width: Self.leftW + Self.starW, alignment: .leading)
            ZStack(alignment: .bottomLeading) {
                HStack(spacing: 0) {
                    ForEach(0..<(Self.guideHours * 2), id: \.self) { n in
                        Text(Fmt.hhmm(windowStart + Double(n) * TimeConst.halfHour))
                            .font(.system(size: 26))
                            .padding(.leading, 10)
                            .frame(width: 30 * Self.ptPerMin, alignment: .leading)
                    }
                }
                .fixedSize()
                .frame(maxHeight: .infinity)
                .offset(x: -CGFloat(hOffsetMin) * Self.ptPerMin)
                // Mũi tên tam giác chỉ xuống vị trí "bây giờ", trượt cùng thanh thời gian
                NowArrow()
                    .fill(Theme.accent)
                    .frame(width: 26, height: 14)
                    .offset(x: nowX - 13)
            }
            .frame(width: max(cellAreaW, 0), height: 56, alignment: .leading)
            .clipped()
        }
        .frame(height: 56)
    }

    // MARK: - Bảng kênh + chương trình

    private var guideArea: some View {
        GeometryReader { geo in
            let rowsFit = max(1, Int(geo.size.height / Self.rowH))
            let areaW = max(geo.size.width - Self.leftW - Self.starW, 200)
            Button(action: activate) {
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        ForEach(visibleRange(rowsFit), id: \.self) { i in
                            guideRow(i, areaW: areaW)
                        }
                    }
                    if shown.isEmpty {
                        Text(emptyText)
                            .font(.system(size: 28))
                            .foregroundStyle(Theme.dim)
                            .padding(30)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .contentShape(Rectangle())
            }
            .buttonStyle(BareButtonStyle())
            .focusEffectDisabled()
            .focused($focus, equals: .guide)
            .disabled(showDrawer)
            .onMoveCommand(perform: move)
            .onPlayPauseCommand {
                if let ch = focusedChannel { store.toggleFavorite(ch) }
            }
            .onAppear { updateGeometry(rowsFit, areaW) }
            .onChange(of: geo.size) { updateGeometry(rowsFit, areaW) }
        }
        .padding(.top, 4)
    }

    private var emptyText: String {
        if sel == 0 { return "Chưa có kênh yêu thích. Bấm ▶︎❙❙ trên remote khi đang chọn kênh để thêm." }
        if store.loading { return "Đang tải danh sách kênh…" }
        if store.playlistUrl.isEmpty { return "Chưa có playlist. Bấm ◄ rồi chọn Cài đặt." }
        return "Không có kênh nào."
    }

    private func updateGeometry(_ rows: Int, _ areaW: CGFloat) {
        if visibleRows != rows { visibleRows = rows }
        if cellAreaW != areaW { cellAreaW = areaW }
    }

    private func visibleRange(_ rows: Int) -> [Int] {
        let n = shown.count
        guard n > 0 else { return [] }
        let start = max(0, min(topRow, n - 1))
        return Array(start..<min(n, start + rows))
    }

    @ViewBuilder
    private func guideRow(_ i: Int, areaW: CGFloat) -> some View {
        let ch = shown[i]
        let isRow = i == row
        let cells = cellsFor(ch)
        let selIdx = (isRow && col == .cell) ? selectedCellIndex(cells) : nil
        let h = Self.rowH - 6

        HStack(spacing: 0) {
            // Cột trái: số kênh, logo, tên
            HStack(spacing: 14) {
                Text("\(i + 1)")
                    .font(.system(size: 26))
                    .foregroundStyle(Theme.dim)
                    .frame(width: 72, alignment: .leading)
                LogoView(url: ch.logo, size: 62)
                Text(ch.name)
                    .font(.system(size: 30, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(width: Self.leftW - 4, height: h)
            .background(SelectionBox(on: isRow && col == .header, dimmed: isRow && col != .header))
            .padding(2)

            // ☆ yêu thích
            Text(store.isFavorite(ch) ? "★" : "☆")
                .font(.system(size: 40))
                .foregroundStyle(Theme.gold)
                .frame(width: Self.starW - 4, height: h)
                .background(SelectionBox(on: isRow && col == .star, dimmed: false))
                .padding(2)

            // Các ô chương trình (trượt ngang cùng nhau)
            HStack(spacing: 0) {
                ForEach(Array(cells.enumerated()), id: \.offset) { k, c in
                    cellView(c, selected: k == selIdx, height: h)
                }
            }
            .fixedSize()
            .offset(x: -CGFloat(hOffsetMin) * Self.ptPerMin)
            .frame(width: areaW, height: Self.rowH, alignment: .leading)
            .clipped()
        }
        .frame(height: Self.rowH)
    }

    private func cellView(_ c: GuideCell, selected: Bool, height: CGFloat) -> some View {
        let w = CGFloat((c.end - c.start) / 60) * Self.ptPerMin
        let base: Color = c.programme == nil ? Theme.cellEmpty : (c.contains(now) ? Theme.cellLive : Theme.cellNormal)
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Text(c.programme?.title ?? "Không có thông tin")
            .font(.system(size: 26))
            .foregroundStyle(c.programme == nil ? Theme.dim : Color.white)
            .lineLimit(1)
            .padding(.horizontal, w > 60 ? 14 : 2)
            .frame(width: max(w - 4, 0), height: height, alignment: .leading)
            .background(shape.fill(selected ? Theme.focusBg : base))
            .overlay(shape.stroke(selected ? Theme.accent : Color.clear, lineWidth: 3))
            .padding(2)
    }

    // MARK: - Ngăn nhóm kênh (trượt từ bên trái)

    private var drawer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Nhóm kênh")
                .font(.system(size: 40, weight: .bold))
            Text("Bấm ► để quay lại danh sách kênh")
                .font(.system(size: 22))
                .foregroundStyle(Theme.dim)
                .padding(.bottom, 6)

            TextField("Tìm kênh…", text: $query)
                .font(.system(size: 28))
                .autocorrectionDisabled()
                .focused($focus, equals: .search)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(labels.enumerated()), id: \.offset) { i, label in
                            Button(action: closeDrawer) {
                                HStack {
                                    Text(label)
                                        .foregroundStyle(i == sel ? Theme.accent : Color.white)
                                        .fontWeight(i == sel ? .bold : .regular)
                                        .lineLimit(1)
                                    Spacer(minLength: 10)
                                    Text("\(i < counts.count ? counts[i] : 0)")
                                        .font(.system(size: 22))
                                        .foregroundStyle(Theme.dim)
                                }
                                .font(.system(size: 28))
                            }
                            .buttonStyle(TvRowButtonStyle(padding: EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20)))
                            .focused($focus, equals: .group(i))
                            .onMoveCommand { if $0 == .right { closeDrawer() } }
                            .id(i)
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 6)
                }
                .onAppear { proxy.scrollTo(sel, anchor: .center) }
            }

            Rectangle().fill(Theme.line).frame(height: 2)

            Button { store.refresh() } label: {
                Text(store.loading ? "Đang làm mới…" : "Làm mới").font(.system(size: 28))
            }
            .buttonStyle(TvRowButtonStyle())
            .focused($focus, equals: .refresh)
            .onMoveCommand { if $0 == .right { closeDrawer() } }

            Button {
                closeDrawer()
                onSettings()
            } label: {
                Text("Cài đặt").font(.system(size: 28))
            }
            .buttonStyle(TvRowButtonStyle())
            .focused($focus, equals: .settings)
            .onMoveCommand { if $0 == .right { closeDrawer() } }

            VStack(alignment: .leading, spacing: 4) {
                if store.loading {
                    HStack(spacing: 12) {
                        ProgressView().scaleEffect(0.6)
                        Text("Đang tải…")
                    }
                }
                Text(statusText)
                Text("Phiên bản \(Fmt.appVersion)")
                if let e = store.error {
                    Text(e).foregroundStyle(Theme.error).lineLimit(2)
                }
            }
            .font(.system(size: 20))
            .foregroundStyle(Theme.dim)
            .padding(.leading, 20)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 30)
        .frame(width: 600)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(hex: 0x091220, alpha: 0.97).ignoresSafeArea())
        .focusSection()
        .onExitCommand(perform: closeDrawer)   // Back khi đang mở ngăn thì đóng ngăn (không thoát app)
    }

    private var statusText: String {
        var s = "\(store.channels.count) kênh"
        if let d = store.lastUpdated { s += " · cập nhật \(Fmt.hhmm(d))" }
        return s
    }
}

private struct PreviewKey: Equatable {
    let url: String?
    let active: Bool
}

/// Nền + viền cho ô đang được chọn trên bảng lịch
private struct SelectionBox: View {
    let on: Bool
    let dimmed: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        ZStack {
            shape.fill(on ? Theme.focusBg : (dimmed ? Color.white.opacity(0.06) : Color.clear))
            shape.stroke(on ? Theme.accent : Color.clear, lineWidth: 3)
        }
    }
}

/// Tam giác chỉ xuống
private struct NowArrow: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}
