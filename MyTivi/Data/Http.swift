import Foundation

enum Http {
    struct HTTPError: LocalizedError {
        let code: Int
        var errorDescription: String? { "HTTP \(code)" }
    }

    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 60       // chờ dữ liệu tối đa 60 giây
        c.timeoutIntervalForResource = 15 * 60
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpAdditionalHeaders = ["User-Agent": StreamURL.defaultUserAgent]
        return URLSession(configuration: c)
    }()

    private static func request(_ raw: String) throws -> URLRequest {
        guard let parsed = StreamURL.parse(raw) else { throw URLError(.badURL) }
        var req = URLRequest(url: parsed.url)
        for (k, v) in parsed.headers { req.setValue(v, forHTTPHeaderField: k) }
        return req
    }

    private static func check(_ resp: URLResponse) throws {
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
            throw HTTPError(code: h.statusCode)
        }
    }

    /// Tải về bộ nhớ (playlist). Tự giải nén nếu là gzip.
    static func data(_ url: String) async throws -> Data {
        let (data, resp) = try await session.data(for: request(url))
        try check(resp)
        return try Gzip.unzipIfNeeded(data)
    }

    /// Tải nguyên bản (giữ nguyên .gz nếu có) về file, thay file cũ khi đã tải xong.
    static func download(_ url: String, to dest: URL) async throws {
        let (tmp, resp) = try await session.download(for: request(url))
        defer { try? FileManager.default.removeItem(at: tmp) }
        try check(resp)
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            _ = try fm.replaceItemAt(dest, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: dest)
        }
    }

    /// Đọc text: UTF-8, không được thì thử Latin-1.
    static func text(_ data: Data) -> String {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(decoding: data, as: UTF8.self)
    }
}
