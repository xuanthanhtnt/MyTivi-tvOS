import Foundation

/// Cài đặt lưu trong UserDefaults (tvOS giới hạn khoảng 500 KB — đủ cho link và danh sách yêu thích).
final class Prefs {
    private let d = UserDefaults.standard

    var playlistUrl: String {
        get { d.string(forKey: "playlist_url") ?? "" }
        set { d.set(newValue, forKey: "playlist_url") }
    }

    /// Link EPG người dùng tự nhập (ưu tiên hơn link EPG ghi sẵn trong playlist).
    var epgUrl: String {
        get { d.string(forKey: "epg_url") ?? "" }
        set { d.set(newValue, forKey: "epg_url") }
    }

    /// Link EPG đọc từ dòng #EXTM3U url-tvg="..." của playlist.
    var autoEpgUrl: String {
        get { d.string(forKey: "epg_auto") ?? "" }
        set { d.set(newValue, forKey: "epg_auto") }
    }

    /// Link EPG của file cache hiện có (để biết khi nào phải tải lại).
    var epgSource: String {
        get { d.string(forKey: "epg_source") ?? "" }
        set { d.set(newValue, forKey: "epg_source") }
    }

    var playlistTime: TimeInterval {
        get { d.double(forKey: "playlist_time") }
        set { d.set(newValue, forKey: "playlist_time") }
    }

    var epgTime: TimeInterval {
        get { d.double(forKey: "epg_time") }
        set { d.set(newValue, forKey: "epg_time") }
    }

    var lastChannelUrl: String {
        get { d.string(forKey: "last_channel") ?? "" }
        set { d.set(newValue, forKey: "last_channel") }
    }

    var favorites: Set<String> {
        get { Set(d.stringArray(forKey: "favorites") ?? []) }
        set { d.set(Array(newValue), forKey: "favorites") }
    }
}
