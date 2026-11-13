import Foundation

/// Cài đặt lưu trong UserDefaults (tvOS giới hạn khoảng 500 KB — đủ cho các link và danh sách yêu thích).
final class Prefs {
    private let d = UserDefaults.standard

    // ---- Nhiều nguồn (bản mới) ----

    /// Đã có danh sách nguồn kiểu mới chưa (chưa có = bản cũ, cần chuyển link cũ sang).
    var hasSourceLists: Bool { d.object(forKey: "playlists") != nil }

    /// Các danh sách kênh M3U, theo thứ tự người dùng xếp.
    var playlists: [Source] {
        get { decode(d.data(forKey: "playlists")) }
        set { d.set(encode(newValue), forKey: "playlists") }
    }

    /// Các link EPG người dùng tự thêm (link ở trên được ưu tiên khi trùng kênh).
    var epgSources: [Source] {
        get { decode(d.data(forKey: "epg_sources")) }
        set { d.set(encode(newValue), forKey: "epg_sources") }
    }

    /// Tự dùng link EPG ghi sẵn trong playlist (#EXTM3U url-tvg="...").
    var useAutoEpg: Bool {
        get { d.object(forKey: "use_auto_epg") as? Bool ?? true }
        set { d.set(newValue, forKey: "use_auto_epg") }
    }

    /// Các link EPG đọc được từ url-tvg của những playlist đang bật.
    var autoEpgUrls: [String] {
        get { d.stringArray(forKey: "epg_auto_list") ?? [] }
        set { d.set(newValue, forKey: "epg_auto_list") }
    }

    // ---- Bản cũ (1 link): chỉ còn dùng để chuyển sang danh sách nguồn ----
    var legacyPlaylistUrl: String { d.string(forKey: "playlist_url") ?? "" }
    var legacyEpgUrl: String { d.string(forKey: "epg_url") ?? "" }
    var legacyAutoEpgUrl: String { d.string(forKey: "epg_auto") ?? "" }
    /// Link EPG của file cache cũ "epg.cache".
    var legacyEpgCacheUrl: String { d.string(forKey: "epg_source") ?? "" }

    var lastChannelUrl: String {
        get { d.string(forKey: "last_channel") ?? "" }
        set { d.set(newValue, forKey: "last_channel") }
    }

    var favorites: Set<String> {
        get { Set(d.stringArray(forKey: "favorites") ?? []) }
        set { d.set(Array(newValue), forKey: "favorites") }
    }

    private func encode(_ list: [Source]) -> Data {
        (try? JSONEncoder().encode(list)) ?? Data("[]".utf8)
    }

    private func decode(_ data: Data?) -> [Source] {
        guard let data, let list = try? JSONDecoder().decode([Source].self, from: data) else { return [] }
        return list.filter { !$0.id.isEmpty && !$0.url.isEmpty }
    }
}
