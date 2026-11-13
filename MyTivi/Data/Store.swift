import CryptoKit
import Foundation

/// Trạng thái chung của app: kênh, yêu thích, EPG, cache, tự cập nhật.
/// (Tương đương MainViewModel.kt của bản Android.)
///
/// Nhiều nguồn:
///  - Kênh của mọi danh sách đang bật được gộp lại (Channel.src = id danh sách).
///  - Các EPG tải lần lượt rồi gộp theo tvg-id; link ở trên được ưu tiên khi trùng kênh.
///    Link url-tvg ghi sẵn trong playlist (nếu bật) được dùng sau các link tự thêm.
///  - Mỗi nguồn có file cache riêng: playlist_<id>.m3u, epg_<mã link>.cache.
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
    @Published private(set) var playlists: [Source] = []
    @Published private(set) var epgSources: [Source] = []
    @Published private(set) var useAutoEpg = true

    let prefs = Prefs()
    private let dir: URL
    private var refreshTask: Task<Void, Never>?
    private var refreshing = false
    private var epgTask: Task<Void, Never>?
    private var loopTask: Task<Void, Never>?
    private var generation = 0

    /// Sau khi tải playlist: tải EPG khi đã cũ / luôn đọc lại (dùng cache nếu còn mới) / luôn tải lại.
    private enum EpgMode { case ifStale, reload, force }

    /// Một việc tải playlist (chạy song song, ngoài luồng giao diện).
    private struct PlaylistJob: Sendable {
        let source: Source
        let file: URL
        let network: Bool
    }

    private struct PlaylistResult: Sendable {
        let source: Source
        let channels: [Channel]?
        let epgUrl: String?
        let error: String?
    }

    var hasPlaylists: Bool { !playlists.isEmpty }
    var lastChannelUrl: String {
        get { prefs.lastChannelUrl }
        set { prefs.lastChannelUrl = newValue }
    }

    nonisolated static func newSourceId() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(10))
    }

    init() {
        // tvOS không có bộ nhớ lâu dài cho app: dùng thư mục Caches (hệ thống có thể xóa khi thiếu chỗ,
        // khi đó app tự tải lại).
        dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyTivi", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        favorites = prefs.favorites
        migrateLegacy()
        playlists = prefs.playlists
        epgSources = prefs.epgSources
        useAutoEpg = prefs.useAutoEpg
        lastUpdated = newestPlaylistDate()
        startLoop()
    }

    /// Bản cũ chỉ có 1 link playlist + 1 link EPG: chuyển thành "Danh sách 1" / "EPG 1", giữ luôn file cache.
    private func migrateLegacy() {
        guard !prefs.hasSourceLists else { return }
        let fm = FileManager.default
        var lists: [Source] = []
        let oldUrl = prefs.legacyPlaylistUrl
        if !oldUrl.isEmpty {
            let s = Source(id: Store.newSourceId(), name: "Danh sách 1", url: oldUrl)
            lists.append(s)
            try? fm.moveItem(at: dir.appendingPathComponent("playlist.m3u"), to: playlistFile(s.id))
        }
        var epgs: [Source] = []
        let oldEpg = prefs.legacyEpgUrl
        if !oldEpg.isEmpty { epgs.append(Source(id: Store.newSourceId(), name: "EPG 1", url: oldEpg)) }
        let cacheUrl = prefs.legacyEpgCacheUrl
        if !cacheUrl.isEmpty {
            try? fm.moveItem(at: dir.appendingPathComponent("epg.cache"), to: epgFile(cacheUrl))
        }
        let auto = prefs.legacyAutoEpgUrl
        if !auto.isEmpty { prefs.autoEpgUrls = [auto] }
        prefs.epgSources = epgs
        prefs.playlists = lists          // ghi sau cùng: có khóa "playlists" = đã chuyển xong
    }

    private func setChannels(_ list: [Channel]) {
        channels = list
        revision += 1
    }

    private func startLoop() {
        loopTask = Task {
            if hasPlaylists {
                // 1) Hiện ngay dữ liệu đã lưu (kênh + EPG), 2) rồi cập nhật từ mạng
                await showCached()
                startRefresh(forcePlaylists: true, epgMode: .ifStale)
            }
            // Vòng lặp tự cập nhật: Apple TV để mở nhiều ngày vẫn luôn có dữ liệu mới
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Store.checkEvery * 1_000_000_000))
                refreshIfStale()
            }
        }
    }

    private func showCached() async {
        let jobs = playlists.filter(\.enabled).map { PlaylistJob(source: $0, file: playlistFile($0.id), network: false) }
        let results = await Store.fetchAll(jobs)
        if channels.isEmpty {
            let all = results.flatMap { $0.channels ?? [] }
            if !all.isEmpty { setChannels(all) }
        }
        loadEpg(cacheOnly: true)
    }

    /// Lưu danh sách nguồn từ màn hình Cài đặt.
    func saveSources(playlists newPlaylists: [Source], epgs newEpgs: [Source], useAutoEpg auto: Bool) {
        // Danh sách đổi link thì bỏ file cache cũ (để không hiện kênh của link cũ)
        for s in newPlaylists {
            if let old = playlists.first(where: { $0.id == s.id }), old.url != s.url {
                try? FileManager.default.removeItem(at: playlistFile(s.id))
            }
        }
        let epgChanged = newEpgs != epgSources || auto != useAutoEpg
        playlists = newPlaylists
        epgSources = newEpgs
        useAutoEpg = auto
        prefs.playlists = newPlaylists
        prefs.epgSources = newEpgs
        prefs.useAutoEpg = auto
        // Bỏ ngay kênh của danh sách đã xóa / tắt / đổi link, phần còn lại giữ nguyên trong lúc tải
        let keep = Set(newPlaylists.filter(\.enabled).map(\.id))
        let stillCached = channels.filter { keep.contains($0.src) && FileManager.default.fileExists(atPath: playlistFile($0.src).path) }
        setChannels(stillCached)
        if epgChanged { epg = [:] }
        if keep.isEmpty {
            refreshTask?.cancel()
            epgTask?.cancel()
            generation += 1
            loading = false
            refreshing = false
            epg = [:]
            error = nil
            return
        }
        startRefresh(forcePlaylists: false, epgMode: .reload)
    }

    /// Nút "Làm mới": tải lại mọi playlist và EPG. Đang tải dở thì bỏ qua (bấm 2 lần không tạo 2 lượt tải).
    func refresh() {
        if refreshing { return }
        startRefresh(forcePlaylists: true, epgMode: .force)
    }

    /// Gọi khi app quay lại từ nền và mỗi 15 phút: dữ liệu đã cũ thì cập nhật.
    func refreshIfStale() {
        guard hasPlaylists, !refreshing else { return }
        let stale = playlists.contains { $0.enabled && Store.isStale(playlistFile($0.id), Store.playlistTTL) }
        if stale {
            startRefresh(forcePlaylists: false, epgMode: .ifStale)
        } else if epgStale {
            loadEpg()
        }
    }

    /// forcePlaylists = true: tải lại mọi playlist; false: chỉ tải danh sách chưa có cache hoặc đã cũ.
    private func startRefresh(forcePlaylists: Bool, epgMode: EpgMode) {
        let active = playlists.filter(\.enabled)
        guard !active.isEmpty else { return }
        generation += 1
        let gen = generation
        refreshTask?.cancel()
        loading = true
        refreshing = true
        error = nil
        let jobs = active.map { s -> PlaylistJob in
            let file = playlistFile(s.id)
            return PlaylistJob(source: s, file: file, network: forcePlaylists || Store.isStale(file, Store.playlistTTL))
        }
        refreshTask = Task {
            let results = await Store.fetchAll(jobs)
            if Task.isCancelled || gen != generation { return }
            apply(results)
            loading = false
            refreshing = false
            switch epgMode {
            case .force: loadEpg(force: true)
            case .reload: loadEpg()
            case .ifStale: if epgStale { loadEpg() }
            }
            cleanupCaches()
        }
    }

    private func apply(_ results: [PlaylistResult]) {
        var all: [Channel] = []
        var autoUrls: [String] = []
        var failed: [String] = []
        for r in results {
            if let list = r.channels { all += list }
            if let u = r.epgUrl, !u.isEmpty, !autoUrls.contains(u) { autoUrls.append(u) }
            if let e = r.error { failed.append("\(r.source.name) (\(e))") }
        }
        setChannels(all)
        prefs.autoEpgUrls = autoUrls
        lastUpdated = newestPlaylistDate()
        if !failed.isEmpty {
            error = "Không tải được: " + failed.joined(separator: ", ") + (all.isEmpty ? "" : " – đang dùng bản đã lưu.")
        } else if all.isEmpty {
            error = "Playlist không có kênh nào."
        }
    }

    /// Tải song song các playlist; lỗi mạng thì dùng file đã lưu (nếu có). Kết quả giữ đúng thứ tự.
    nonisolated private static func fetchAll(_ jobs: [PlaylistJob]) async -> [PlaylistResult] {
        await withTaskGroup(of: (Int, PlaylistResult).self) { group in
            for (i, job) in jobs.enumerated() {
                group.addTask { (i, await Store.fetchOne(job)) }
            }
            var out = [PlaylistResult?](repeating: nil, count: jobs.count)
            for await (i, r) in group { out[i] = r }
            return out.compactMap { $0 }
        }
    }

    nonisolated private static func fetchOne(_ job: PlaylistJob) async -> PlaylistResult {
        let s = job.source
        func fromCache(_ err: String?) -> PlaylistResult {
            guard let data = try? Data(contentsOf: job.file) else {
                return PlaylistResult(source: s, channels: nil, epgUrl: nil, error: err)
            }
            let p = Store.parse(data: data, sourceURL: s.url, src: s.id)
            return PlaylistResult(source: s, channels: p.channels, epgUrl: p.epgUrl, error: err)
        }
        guard job.network else { return fromCache(nil) }
        do {
            let data = try await Http.data(s.url)
            try Task.checkCancellation()                          // lượt này đã bị hủy thì không ghi đè cache
            try data.write(to: job.file, options: .atomic)        // ghi qua file tạm, không bao giờ ghi dở
            let p = Store.parse(data: data, sourceURL: s.url, src: s.id)
            return PlaylistResult(source: s, channels: p.channels, epgUrl: p.epgUrl, error: nil)
        } catch {
            if Task.isCancelled { return PlaylistResult(source: s, channels: nil, epgUrl: nil, error: nil) }
            return fromCache(error.localizedDescription)
        }
    }

    // MARK: - EPG

    /// Thứ tự ưu tiên: các link tự thêm (đang bật), rồi link url-tvg ghi sẵn trong playlist.
    private var epgUrls: [String] {
        var out = epgSources.filter(\.enabled).map(\.url)
        if useAutoEpg { out += prefs.autoEpgUrls }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    private var epgStale: Bool {
        epgUrls.contains { Store.isStale(epgFile($0), Store.epgTTL) }
    }

    /// EPG được lưu thành file cache nên mở app lần sau có lịch ngay.
    /// cacheOnly = true: chỉ đọc file đã lưu (không dùng mạng).
    private func loadEpg(force: Bool = false, cacheOnly: Bool = false) {
        let jobs = epgUrls.map { ($0, epgFile($0)) }
        epgTask?.cancel()
        guard !jobs.isEmpty else {
            if !cacheOnly { epg = [:] }
            return
        }
        epgTask = Task {
            var merged: EPG = [:]
            var any = false
            for (url, file) in jobs {
                if Task.isCancelled { return }
                let exists = FileManager.default.fileExists(atPath: file.path)
                if cacheOnly && !exists { continue }
                if !cacheOnly && (force || Store.isStale(file, Store.epgTTL)) {
                    do {
                        try await Http.download(url, to: file)
                    } catch {
                        // Tải lỗi thì dùng tạm file cũ (nếu có), 15 phút sau sẽ thử lại
                        if Task.isCancelled { return }
                        if !exists { continue }
                    }
                }
                let result = try? await Task.detached(priority: .utility) {
                    try EPGParser.parse(fileURL: file, now: Date().timeIntervalSince1970)
                }.value
                if Task.isCancelled { return }
                guard let result else { continue }    // EPG lỗi thì bỏ qua, vẫn xem kênh bình thường
                any = true
                for (k, v) in result where merged[k] == nil { merged[k] = v }   // link ở trên được ưu tiên
                if epg.isEmpty { epg = merged }        // chưa có lịch thì hiện ngay phần đã đọc được
            }
            if Task.isCancelled { return }
            if any { epg = merged }
        }
    }

    // MARK: - File cache

    private func playlistFile(_ id: String) -> URL { dir.appendingPathComponent("playlist_\(id).m3u") }
    private func epgFile(_ url: String) -> URL { dir.appendingPathComponent("epg_\(Store.hash(url)).cache") }

    private func newestPlaylistDate() -> Date? {
        playlists.filter(\.enabled).compactMap { Store.modified(playlistFile($0.id)) }.max()
    }

    /// Xóa file cache của nguồn đã bỏ (và file của bản cũ).
    private func cleanupCaches() {
        var keep = Set(playlists.map { playlistFile($0.id).lastPathComponent })
        let allEpg = epgSources.map(\.url) + prefs.autoEpgUrls
        keep.formUnion(allEpg.map { epgFile($0).lastPathComponent })
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names where !keep.contains(name) {
            let isCache = (name.hasPrefix("playlist") && name.hasSuffix(".m3u"))
                || (name.hasPrefix("epg_") && name.hasSuffix(".cache"))
                || name == "epg.cache"
            if isCache { try? fm.removeItem(at: dir.appendingPathComponent(name)) }
        }
    }

    nonisolated private static func modified(_ file: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }

    nonisolated private static func isStale(_ file: URL, _ ttl: TimeInterval) -> Bool {
        guard let d = modified(file) else { return true }
        return Date().timeIntervalSince(d) > ttl
    }

    nonisolated private static func hash(_ s: String) -> String {
        Insecure.SHA1.hash(data: Data(s.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Yêu thích

    func isFavorite(_ ch: Channel) -> Bool { favorites.contains(ch.url) }

    func toggleFavorite(_ ch: Channel) {
        if favorites.contains(ch.url) { favorites.remove(ch.url) } else { favorites.insert(ch.url) }
        prefs.favorites = favorites
    }

    /// Link là một luồng HLS đơn (không phải danh sách kênh) thì coi như 1 kênh.
    /// Kênh trùng hoàn toàn (cùng nhóm + cùng link) chỉ giữ 1.
    nonisolated static func parse(data: Data, sourceURL: String, src: String) -> ParsedPlaylist {
        let text = Http.text(data)
        var parsed = M3UParser.parse(text)
        if parsed.channels.isEmpty && text.contains("#EXT-X-") {
            return ParsedPlaylist(
                channels: [Channel(tvgId: "", name: "Luồng trực tiếp", url: sourceURL, logo: "", group: "Khác", src: src)],
                epgUrl: nil
            )
        }
        var seen = Set<String>()
        parsed.channels = parsed.channels.compactMap { ch in
            var c = ch
            c.src = src
            return seen.insert(c.id).inserted ? c : nil
        }
        return parsed
    }
}
