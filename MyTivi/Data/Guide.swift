import Foundation

enum TimeConst {
    static let minute: TimeInterval = 60
    static let halfHour: TimeInterval = 30 * 60
    static let hour: TimeInterval = 3600
}

func floorTo(_ t: TimeInterval, _ step: TimeInterval) -> TimeInterval {
    (t / step).rounded(.down) * step
}

/// Một ô trên bảng lịch. programme = nil nghĩa là "Không có thông tin".
struct GuideCell: Hashable {
    let start: TimeInterval
    let end: TimeInterval
    let programme: Programme?

    func contains(_ t: TimeInterval) -> Bool { t >= start && t < end }
}

/// Chia khoảng [from, to) của một kênh thành các ô liên tiếp:
/// chương trình có trong EPG thì thành một ô, khoảng trống thì chia thành các khối 1 giờ.
func buildCells(_ list: [Programme]?, from: TimeInterval, to: TimeInterval) -> [GuideCell] {
    var result: [GuideCell] = []
    var cursor = from

    func fillGap(_ until: TimeInterval) {
        while cursor < until {
            let end = min(floorTo(cursor, TimeConst.hour) + TimeConst.hour, until)
            result.append(GuideCell(start: cursor, end: end, programme: nil))
            cursor = end
        }
    }

    for p in list ?? [] {
        if p.stop <= cursor || p.start >= to { continue }
        if p.start > cursor { fillGap(p.start) }
        let end = min(p.stop, to)
        result.append(GuideCell(start: cursor, end: end, programme: p))
        cursor = end
    }
    if cursor < to { fillGap(to) }
    return result
}
