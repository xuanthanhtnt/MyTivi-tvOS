import Foundation

/// Đọc playlist M3U/M3U8 dạng IPTV: #EXTINF:-1 tvg-id="" tvg-logo="" group-title="",Tên kênh
enum M3UParser {
    private static let attrRegex = try! NSRegularExpression(pattern: "([\\w-]+)=\"([^\"]*)\"")

    static func parse(_ text: String) -> ParsedPlaylist {
        var channels: [Channel] = []
        var epgUrl: String?
        var attrs: [String: String] = [:]
        var name = ""
        var extGroup: String?
        var pending = false

        // Character "\r\n" cũng là newline nên split xử lý được cả file Windows
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            while line.hasPrefix("\u{FEFF}") { line.removeFirst() }

            if line.hasPrefix("#EXTM3U") {
                let a = readAttrs(line)
                if let u = a["url-tvg"] ?? a["x-tvg-url"] {
                    let first = u.split(separator: ",", maxSplits: 1).first.map(String.init) ?? u
                    epgUrl = first.trimmingCharacters(in: .whitespaces)
                }
            } else if line.hasPrefix("#EXTINF") {
                attrs = readAttrs(line)
                name = nameAfterComma(line)
                pending = true
            } else if line.hasPrefix("#EXTGRP:") {
                extGroup = String(line.dropFirst("#EXTGRP:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.isEmpty || line.hasPrefix("#") {
                continue
            } else if pending {
                var finalName = name
                if finalName.isEmpty { finalName = attrs["tvg-name"] ?? "Kênh \(channels.count + 1)" }
                var group = attrs["group-title"] ?? extGroup ?? ""
                if group.trimmingCharacters(in: .whitespaces).isEmpty { group = "Khác" }
                channels.append(Channel(
                    tvgId: attrs["tvg-id"] ?? "",
                    name: finalName,
                    url: line,
                    logo: attrs["tvg-logo"] ?? "",
                    group: group
                ))
                pending = false
                extGroup = nil
            }
        }
        return ParsedPlaylist(channels: channels, epgUrl: epgUrl)
    }

    private static func readAttrs(_ line: String) -> [String: String] {
        var out: [String: String] = [:]
        let ns = line as NSString
        for m in attrRegex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            out[ns.substring(with: m.range(at: 1)).lowercased()] = ns.substring(with: m.range(at: 2))
        }
        return out
    }

    /// Tên kênh nằm sau dấu phẩy đầu tiên nằm NGOÀI cặp ngoặc kép.
    private static func nameAfterComma(_ line: String) -> String {
        var inQuote = false
        var idx = line.startIndex
        while idx < line.endIndex {
            let c = line[idx]
            if c == "\"" {
                inQuote.toggle()
            } else if c == "," && !inQuote {
                return String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            }
            idx = line.index(after: idx)
        }
        return ""
    }
}

/// Link dạng `http://.../a.m3u8|User-Agent=abc&Referer=http://...` -> URL + header riêng.
enum StreamURL {
    static let defaultUserAgent = "MyTivi/1.0"

    static func parse(_ raw: String) -> (url: URL, headers: [String: String])? {
        let parts = raw.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let base = String(parts[0]).trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: base) ?? URL(string: base.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "") else {
            return nil
        }
        var headers = ["User-Agent": defaultUserAgent]
        if parts.count > 1 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                guard kv.count == 2 else { continue }
                let key = String(kv[0]).trimmingCharacters(in: .whitespaces)
                let value = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                if !key.isEmpty { headers[key] = value }
            }
        }
        return (url, headers)
    }
}
