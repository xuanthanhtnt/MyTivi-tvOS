import Foundation

/// Trạng thái chung của app: kênh, yêu thích, EPG, cache, tự cập nhật.
/// (Tương đương MainViewModel.kt của bản Android.)
@MainActor
final class Store: ObservableObject {
    // Chỉnh các mốc này nếu muốn cập nhật thưa hoặc dày hơn
    static let playlistTTL: TimeInterval = 3 * 3600   // tải lại playlist sau 3 giờ
    static let epgTTL: TimeInterval = 6 * 3600        // tải lại EPG sau 6 giờ
    static let checkEvery: TimeInterval = 15 * 60     // cứ 15 phút kiểm tra một lần

    @Published private(set) var channels: [Channel] = []
    /// Tăng mỗi lần danh sách kênh đổi (so sánh rẻ hơn so cả mảng)
    @Published private(set) var revision = 0
    @Published private(set) var epg: EPG = [:]
    @Published private(set) var favorites: Set<String> = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var lastUpdated: Date?

    let prefs = Prefs()
    private let cacheFile: URL
    private let epgFile: URL
    private var refreshTask: Task<Void, Never>?
    private var refreshing = false
    private var epgTask: Task<Void, Never>?
    private var loopTask: Task<Void, Never>?
    private var generation = 0

    var playlistUrl: String { prefs.playlistUrl }
    var epgUrl: String { prefs.epgUrl }
    var lastChannelUrl: String {
        get { prefs.lastChannelUrl }
        set { prefs.lastChannelUrl = newValue }
    }

    init() {
        // tvOS không có bộ nhớ lâu dài cho app: dùng thư mục Caches (hệ thống có thể xóa khi thiếu chỗ,
        // khi đó app tự tải lại).
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyTivi", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cacheFile = dir.appendingPathComponent("playlist.m3u")
        epgFile = dir.appendingPathComponent("epg.cache")
        favorites = prefs.favorites
        if prefs.playlistTime > 0 { lastUpdated = Date(timeIntervalSince1970: prefs.playlistTime) }
        startLoop()
    }

    private func setChannels(_ list: [Channel]) {
        channels = list
        revision += 1
    }

    private func startLoop() {
        loopTask = Task {
            if !prefs.playlistUrl.isEmpty {
                // 1) Hiện ngay dữ liệu đã lưu (kênh + EPG), 2) rồi cập nhật từ mạng
                if FileManager.default.fileExists(atPath: cacheFile.path) {
                    let file = cacheFile
                    let url = prefs.playlistUrl
                    let parsed = await Task.detached(priority: .userInitiated) { () -> ParsedPlaylist? in
                        guard let data = try? Data(contentsOf: file) else { return nil }
                        return Store.parse(data: data, sourceURL: url)
                    }.value
                    if let parsed, channels.isEmpty { setChannels(parsed.channels) }
                    loadEpg(cacheOnly: true)
                }
                startRefresh(forceEpg: false)
            }
            // Vòng lặp tự cập nhật: Apple TV để mở nhiều ngày vẫn luôn có dữ liệu mới
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Store.checkEvery * 1_000_000_000))
                if prefs.playlistUrl.isEmpty { continue }
                if Date().timeIntervalSince1970 - prefs.playlistTime > Store.playlistTTL {
                    startRefresh(forceEpg: false)
                } else if epgStale {
                    loadEpg()
                }
            }
        }
    }

    func savePlaylist(url: String, epgUrl: String) {
        prefs.playlistUrl = url
        prefs.epgUrl = epgUrl
        setChannels([])
        epg = [:]
        startRefresh(forceEpg: true)
    }

    /// Nút "Làm mới": tải lại playlist và EPG. Đang tải dở thì bỏ qua (bấm 2 lần không tạo 2 lượt tải).
    func refresh() {
        if refreshing { return }
        startRefresh(forceEpg: true)
    }

    /// Gọi khi app quay lại từ nền: dữ liệu đã cũ thì cập nhật ngay.
    func refreshIfStale() {
        guard !prefs.playlistUrl.isEmpty, !refreshing else { return }
        if Date().timeIntervalSince1970 - prefs.playlistTime > Store.playlistTTL {
            startRefresh(forceEpg: false)
        } else if epgStale {
            loadEpg()
        }
    }

    /// forceEpg = true: tải lại cả EPG; tự động thì chỉ tải EPG khi đã cũ.
    private func startRefresh(forceEpg: Bool) {
        let url = prefs.playlistUrl
        guard !url.isEmpty else { return }
        generation += 1
        let gen = generation
        refreshTask?.cancel()
        loading = true
        refreshing = true
        error = nil
        let file = cacheFile
        refreshTask = Task {
            do {
                let data = try await Http.data(url)
                try Task.checkCancellation()          // lượt này đã bị hủy thì không ghi đè cache
                let parsed = try await Task.detached(priority: .userInitiated) { () throws -> ParsedPlaylist in
                    try data.write(to: file, options: .atomic)   // ghi qua file tạm, không bao giờ ghi dở
                    return Store.parse(data: data, sourceURL: url)
                }.value
                try Task.checkCancellation()
                setChannels(parsed.channels)
                prefs.autoEpgUrl = parsed.epgUrl ?? ""
                prefs.playlistTime = Date().timeIntervalSince1970
                lastUpdated = Date()
                if parsed.channels.isEmpty { error = "Playlist không có kênh nào." }
                if forceEpg || epgStale { loadEpg(force: forceEpg) }
            } catch {
                if !Task.isCancelled && gen == generation {
                    self.error = "Không tải được playlist: \(error.localizedDescription)"
                }
            }
            if gen == generation {
                loading = false
                refreshing = false
            }
        }
    }

    private var currentEpgUrl: String { prefs.epgUrl.isEmpty ? prefs.autoEpgUrl : prefs.epgUrl }

    private var epgStale: Bool {
        let url = currentEpgUrl
        guard !url.isEmpty else { return false }
        return !FileManager.default.fileExists(atPath: epgFile.path)
            || prefs.epgSource != url
            || Date().timeIntervalSince1970 - prefs.epgTime > Store.epgTTL
    }

    /// EPG được lưu thành file cache nên mở app lần sau có lịch ngay.
    /// cacheOnly = true: chỉ đọc file đã lưu (không dùng mạng).
    private func loadEpg(force: Bool = false, cacheOnly: Bool = false) {
        let url = currentEpgUrl
        guard !url.isEmpty else { return }
        let file = epgFile
        let exists = FileManager.default.fileExists(atPath: file.path)
        if cacheOnly && !exists { return }
        let needDownload = !cacheOnly && (force || epgStale)
        epgTask?.cancel()
        epgTask = Task {
            if needDownload {
                do {
                    try await Http.download(url, to: file)
                    if Task.isCancelled { return }
                    prefs.epgSource = url
                    prefs.epgTime = Date().timeIntervalSince1970
                } catch {
                    // Tải lỗi thì dùng tạm file cũ (nếu có), 15 phút sau sẽ thử lại
                    if Task.isCancelled || !FileManager.default.fileExists(atPath: file.path) { return }
                }
            }
            let result = try? await Task.detached(priority: .utility) {
                try EPGParser.parse(fileURL: file, now: Date().timeIntervalSince1970)
            }.value
            if Task.isCancelled { return }
            if let result { epg = result }      // EPG lỗi thì bỏ qua, vẫn xem kênh bình thường
        }
    }

    func isFavorite(_ ch: Channel) -> Bool { favorites.contains(ch.url) }

    func toggleFavorite(_ ch: Channel) {
        if favorites.contains(ch.url) { favorites.remove(ch.url) } else { favorites.insert(ch.url) }
        prefs.favorites = favorites
    }

    /// Link là một luồng HLS đơn (không phải danh sách kênh) thì coi như 1 kênh.
    /// Kênh trùng hoàn toàn (cùng nhóm + cùng link) chỉ giữ 1.
    nonisolated static func parse(data: Data, sourceURL: String) -> ParsedPlaylist {
        let text = Http.text(data)
        var parsed = M3UParser.parse(text)
        if parsed.channels.isEmpty && text.contains("#EXT-X-") {
            return ParsedPlaylist(
                channels: [Channel(tvgId: "", name: "Luồng trực tiếp", url: sourceURL, logo: "", group: "Khác")],
                epgUrl: nil
            )
        }
        var seen = Set<String>()
        parsed.channels = parsed.channels.filter { seen.insert($0.id).inserted }
        return parsed
    }
}
