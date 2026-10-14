import Foundation

/// Một kênh trong playlist M3U.
struct Channel: Identifiable, Hashable {
    /// tvg-id, dùng để ghép với EPG (có thể rỗng)
    let tvgId: String
    let name: String
    let url: String
    let logo: String
    let group: String

    /// Khóa ổn định cho từng hàng: nhóm + link (kênh trùng hoàn toàn đã bị lọc khi đọc playlist)
    var id: String { group + "\u{0}" + url }
    var epgKey: String { tvgId.lowercased() }
}

struct ParsedPlaylist {
    var channels: [Channel]
    var epgUrl: String?
}

/// Một chương trình trong lịch phát sóng. Thời gian tính bằng giây kể từ 1970 (UTC).
struct Programme: Hashable {
    let start: TimeInterval
    let stop: TimeInterval
    let title: String

    func isLive(at now: TimeInterval) -> Bool { now >= start && now < stop }

    func progress(at now: TimeInterval) -> Double {
        let len = max(stop - start, 1)
        return min(max((now - start) / len, 0), 1)
    }
}

/// tvg-id (chữ thường) -> danh sách chương trình đã sắp theo giờ
typealias EPG = [String: [Programme]]

extension Dictionary where Key == String, Value == [Programme] {
    func programmes(for ch: Channel) -> [Programme]? {
        ch.tvgId.isEmpty ? nil : self[ch.epgKey]
    }

    func nowPlaying(_ ch: Channel, at now: TimeInterval) -> Programme? {
        programmes(for: ch)?.first { $0.isLive(at: now) }
    }

    func nextPlaying(_ ch: Channel, at now: TimeInterval) -> Programme? {
        programmes(for: ch)?.first { $0.start > now }
    }
}
