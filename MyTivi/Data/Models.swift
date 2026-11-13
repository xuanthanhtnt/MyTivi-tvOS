import Foundation

/// Một kênh trong playlist M3U.
struct Channel: Identifiable, Hashable {
    /// tvg-id, dùng để ghép với EPG (có thể rỗng)
    let tvgId: String
    let name: String
    let url: String
    let logo: String
    let group: String
    /// id của danh sách kênh (Source) chứa kênh này
    var src: String = ""

    /// Khóa ổn định cho từng hàng: danh sách + nhóm + link (kênh trùng hoàn toàn đã bị lọc khi đọc playlist)
    var id: String { src + "\u{0}" + group + "\u{0}" + url }
    var epgKey: String { tvgId.lowercased() }
}

struct ParsedPlaylist {
    var channels: [Channel]
    var epgUrl: String?
}

/// Một nguồn người dùng thêm trong Cài đặt: danh sách kênh (M3U) hoặc link lịch phát sóng (EPG).
struct Source: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var url: String
    var enabled: Bool = true
}

/// Một mục trong ngăn nhóm kênh.
///  - key "fav" / "all": Yêu thích / Tất cả
///  - "h:<id>": tiêu đề mục của một danh sách (không chọn được, chỉ hiện khi có từ 2 danh sách)
///  - "src:<id>": tất cả kênh của một danh sách
///  - "grp:<id>\0<nhóm>": một nhóm kênh trong một danh sách
struct GroupEntry: Identifiable, Hashable {
    let key: String
    let label: String
    let count: Int
    var header: Bool = false
    var src: String? = nil
    var group: String? = nil

    var id: String { key }
}

/// Dựng danh sách mục cho ngăn nhóm kênh. Có từ 2 danh sách kênh trở lên thì chia mục theo từng danh sách.
func buildGroupEntries(_ channels: [Channel], favorites: Set<String>, sources: [Source]) -> [GroupEntry] {
    var out = [
        GroupEntry(key: "fav", label: "★ Yêu thích", count: channels.filter { favorites.contains($0.url) }.count),
        GroupEntry(key: "all", label: "Tất cả", count: channels.count),
    ]
    var bySrc: [String: [Channel]] = [:]
    for ch in channels { bySrc[ch.src, default: []].append(ch) }
    let known = sources.filter { bySrc[$0.id] != nil }
    let multi = known.count > 1
    for s in known {
        let list = bySrc[s.id] ?? []
        if multi {
            out.append(GroupEntry(key: "h:\(s.id)", label: s.name, count: list.count, header: true, src: s.id))
            out.append(GroupEntry(key: "src:\(s.id)", label: "Tất cả kênh", count: list.count, src: s.id))
        }
        var order: [String] = []
        var counts: [String: Int] = [:]
        for ch in list {
            if counts[ch.group] == nil { order.append(ch.group) }
            counts[ch.group, default: 0] += 1
        }
        for g in order {
            out.append(GroupEntry(key: "grp:\(s.id)\u{0}\(g)", label: g, count: counts[g] ?? 0, src: s.id, group: g))
        }
    }
    return out
}

/// Các kênh thuộc một mục của ngăn nhóm kênh.
func channelsFor(_ entry: GroupEntry?, _ channels: [Channel], favorites: Set<String>) -> [Channel] {
    guard let e = entry, e.key != "all" else { return channels }
    if e.key == "fav" { return channels.filter { favorites.contains($0.url) } }
    guard let g = e.group else { return channels.filter { $0.src == e.src } }
    return channels.filter { $0.src == e.src && $0.group == g }
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
