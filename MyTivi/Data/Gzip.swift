import Compression
import Foundation

/// Giải nén gzip (nhiều nguồn EPG nén .gz). Framework Compression chỉ hiểu DEFLATE thô,
/// nên tự bỏ phần header gzip rồi giải nén phần còn lại theo từng khối.
enum Gzip {
    enum GzipError: Error { case badHeader, corrupt }

    static func isGzip(_ data: Data) -> Bool {
        data.count > 2 && data[data.startIndex] == 0x1f && data[data.startIndex + 1] == 0x8b
    }

    static func fileIsGzip(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        let head = (try? h.read(upToCount: 2)) ?? Data()
        return isGzip(head)
    }

    /// Dữ liệu là gzip thì giải nén, không thì trả lại nguyên bản.
    static func unzipIfNeeded(_ data: Data) throws -> Data {
        guard isGzip(data) else { return data }
        var out = Data()
        try inflate(data) { out.append($0) }
        return out
    }

    /// Giải nén file .gz ra file khác (không giữ toàn bộ kết quả trong RAM).
    static func decompress(file: URL, to dest: URL) throws {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let out = try FileHandle(forWritingTo: dest)
        defer { try? out.close() }
        try inflate(data) { out.write($0) }
    }

    private static func headerLength(_ d: [UInt8]) throws -> Int {
        guard d.count >= 18, d[0] == 0x1f, d[1] == 0x8b, d[2] == 8 else { throw GzipError.badHeader }
        let flags = d[3]
        var pos = 10
        if flags & 0x04 != 0 {                 // FEXTRA
            guard pos + 2 <= d.count else { throw GzipError.badHeader }
            pos += 2 + Int(d[pos]) + Int(d[pos + 1]) << 8
        }
        if flags & 0x08 != 0 {                 // FNAME
            while pos < d.count && d[pos] != 0 { pos += 1 }
            pos += 1
        }
        if flags & 0x10 != 0 {                 // FCOMMENT
            while pos < d.count && d[pos] != 0 { pos += 1 }
            pos += 1
        }
        if flags & 0x02 != 0 { pos += 2 }      // FHCRC
        guard pos < d.count else { throw GzipError.badHeader }
        return pos
    }

    private static func inflate(_ data: Data, sink: (Data) -> Void) throws {
        let headBytes = [UInt8](data.prefix(4096))
        let header = try headerLength(headBytes)

        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw GzipError.corrupt
        }
        defer { compression_stream_destroy(stream) }

        let bufSize = 1 << 16
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { dst.deallocate() }

        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { throw GzipError.corrupt }
            stream.pointee.src_ptr = base + header
            stream.pointee.src_size = raw.count - header
            var status: compression_status
            repeat {
                stream.pointee.dst_ptr = dst
                stream.pointee.dst_size = bufSize
                status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                guard status == COMPRESSION_STATUS_OK || status == COMPRESSION_STATUS_END else {
                    throw GzipError.corrupt
                }
                let produced = bufSize - stream.pointee.dst_size
                if produced > 0 { sink(Data(bytes: dst, count: produced)) }
            } while status == COMPRESSION_STATUS_OK
        }
    }
}
