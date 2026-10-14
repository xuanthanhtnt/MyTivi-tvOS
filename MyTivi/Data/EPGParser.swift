import Foundation

/// Đọc lịch phát sóng XMLTV. Chỉ giữ các chương trình từ -2 giờ đến +24 giờ để tiết kiệm RAM.
final class EPGParser: NSObject, XMLParserDelegate {
    private let from: TimeInterval
    private let to: TimeInterval
    private var map: [String: [Programme]] = [:]

    private var channel = ""
    private var start: TimeInterval = 0
    private var stop: TimeInterval = 0
    private var wanted = false
    private var inTitle = false
    private var title = ""

    private init(now: TimeInterval) {
        from = now - 2 * 3600
        to = now + 24 * 3600
    }

    /// Đọc file cache (tự giải nén nếu là .gz).
    static func parse(fileURL: URL, now: TimeInterval) throws -> EPG {
        var xmlURL = fileURL
        var tempURL: URL?
        if Gzip.fileIsGzip(fileURL) {
            let tmp = fileURL.deletingLastPathComponent()
                .appendingPathComponent("epg-\(UUID().uuidString).xml")
            try Gzip.decompress(file: fileURL, to: tmp)
            xmlURL = tmp
            tempURL = tmp
        }
        defer { if let tempURL { try? FileManager.default.removeItem(at: tempURL) } }

        guard let stream = InputStream(url: xmlURL) else { throw CocoaError(.fileReadUnknown) }
        let parser = XMLParser(stream: stream)
        let delegate = EPGParser(now: now)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        _ = parser.parse()   // file hỏng một đoạn ở cuối vẫn giữ phần đã đọc được
        return delegate.finish()
    }

    private func finish() -> EPG {
        // Sắp theo giờ và bỏ bản ghi trùng (một số nguồn EPG lặp lại chương trình)
        var out: EPG = [:]
        out.reserveCapacity(map.count)
        for (key, list) in map {
            var seen = Set<TimeInterval>()
            out[key] = list.sorted { $0.start < $1.start }.filter { seen.insert($0.start).inserted }
        }
        return out
    }

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "programme":
            channel = (attributeDict["channel"] ?? "").lowercased()
            start = Self.parseTime(attributeDict["start"])
            stop = Self.parseTime(attributeDict["stop"])
            wanted = !channel.isEmpty && stop > from && start < to
        case "title":
            if wanted {
                inTitle = true
                title = ""
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inTitle { title += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        if elementName == "title" && inTitle {
            inTitle = false
            map[channel, default: []].append(
                Programme(start: start, stop: stop, title: title.trimmingCharacters(in: .whitespacesAndNewlines))
            )
            wanted = false     // chỉ lấy tiêu đề đầu tiên
        } else if elementName == "programme" {
            wanted = false
            inTitle = false
        }
    }

    // MARK: Thời gian XMLTV: "yyyyMMddHHmmss +0700" (không có múi giờ = UTC)

    static func parseTime(_ s: String?) -> TimeInterval {
        guard let s else { return 0 }
        let u = Array(s.utf8)
        guard u.count >= 14 else { return 0 }

        func num(_ at: Int, _ len: Int) -> Int? {
            var v = 0
            for i in at..<(at + len) {
                let c = u[i]
                guard c >= 48 && c <= 57 else { return nil }
                v = v * 10 + Int(c - 48)
            }
            return v
        }
        guard let y = num(0, 4), let mo = num(4, 2), let d = num(6, 2),
              let h = num(8, 2), let mi = num(10, 2), let se = num(12, 2) else { return 0 }

        var offset = 0
        var i = 14
        while i < u.count && u[i] == 32 { i += 1 }        // bỏ dấu cách
        // '+' (43) hoặc '-' (45) theo sau là hhmm
        if i + 4 < u.count && (u[i] == 43 || u[i] == 45),
           let oh = num(i + 1, 2), let om = num(i + 3, 2) {
            offset = (u[i] == 45 ? -1 : 1) * (oh * 3600 + om * 60)
        }
        let days = daysFromCivil(y, mo, d)
        return TimeInterval(days * 86400 + h * 3600 + mi * 60 + se - offset)
    }

    /// Số ngày kể từ 1970-01-01 (thuật toán của Howard Hinnant).
    private static func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (m + 9) % 12
        let doy = (153 * mp + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }
}
