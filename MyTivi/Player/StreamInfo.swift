import AVFoundation
import CoreMedia
import SwiftUI

/// Thông số kỹ thuật của luồng đang phát (giống TiviMate / UHF).
struct StreamInfo: Equatable {
    var width = 0
    var height = 0
    var fps: Double = 0
    var videoCodec: String?
    var audioCodec: String?
    var audioChannels = 0
    var bitrate: Double = 0      // bit/giây

    /// Các nhãn hiển thị, ví dụ: FHD · 1920×1080 · 50 fps · H.264 · AAC 2.0 · 4.2 Mbps
    var badges: [String] {
        var out: [String] = []
        if height > 0 {
            switch height {
            case 2160...: out.append("4K")
            case 1440...: out.append("2K")
            case 1080...: out.append("FHD")
            case 720...: out.append("HD")
            default: out.append("SD")
            }
            if width > 0 { out.append("\(width)×\(height)") }
        }
        if fps > 0 { out.append("\(Int(fps.rounded())) fps") }
        if let videoCodec { out.append(videoCodec) }
        if let audioCodec {
            let ch: String
            switch audioChannels {
            case 1: ch = " Mono"
            case 2: ch = " 2.0"
            case 6: ch = " 5.1"
            case 8: ch = " 7.1"
            default: ch = ""
            }
            out.append(audioCodec + ch)
        }
        if bitrate > 0 { out.append(String(format: "%.1f Mbps", bitrate / 1_000_000)) }
        return out
    }

    /// Đọc thông số từ AVPlayerItem; nil khi chưa có hình/tiếng.
    @MainActor
    static func read(from item: AVPlayerItem) async -> StreamInfo? {
        var info = StreamInfo()
        let size = item.presentationSize
        info.width = Int(size.width.rounded())
        info.height = Int(size.height.rounded())

        for t in item.tracks where t.isEnabled {
            guard let at = t.assetTrack else { continue }
            if at.mediaType == .video {
                if t.currentVideoFrameRate > 0 { info.fps = Double(t.currentVideoFrameRate) }
                if let descs = try? await at.load(.formatDescriptions), let d = descs.first {
                    info.videoCodec = videoName(CMFormatDescriptionGetMediaSubType(d))
                }
                if info.fps <= 0, let r = try? await at.load(.nominalFrameRate), r > 0 {
                    info.fps = Double(r)
                }
            } else if at.mediaType == .audio, info.audioCodec == nil {
                if let descs = try? await at.load(.formatDescriptions), let d = descs.first {
                    info.audioCodec = audioName(CMFormatDescriptionGetMediaSubType(d))
                    if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(d) {
                        info.audioChannels = Int(asbd.pointee.mChannelsPerFrame)
                    }
                }
            }
        }
        if let ev = item.accessLog()?.events.last {
            if ev.indicatedBitrate > 0 {
                info.bitrate = ev.indicatedBitrate
            } else if ev.observedBitrate > 0 {
                info.bitrate = ev.observedBitrate
            }
        }
        if info.height == 0 && info.videoCodec == nil && info.audioCodec == nil { return nil }
        return info
    }

    private static func fourCC(_ c: FourCharCode) -> String {
        let bytes = [UInt8((c >> 24) & 0xFF), UInt8((c >> 16) & 0xFF), UInt8((c >> 8) & 0xFF), UInt8(c & 0xFF)]
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    private static func videoName(_ c: FourCharCode) -> String {
        let s = fourCC(c)
        switch s {
        case "avc1", "avc3": return "H.264"
        case "hvc1", "hev1": return "H.265"
        case "dvh1", "dvhe": return "Dolby Vision"
        case "av01": return "AV1"
        case "vp09": return "VP9"
        case "mp2v": return "MPEG-2"
        case "mp4v": return "MPEG-4"
        default: return s.trimmingCharacters(in: .whitespaces).uppercased()
        }
    }

    private static func audioName(_ c: FourCharCode) -> String {
        let s = fourCC(c)
        switch s {
        case "aac ": return "AAC"
        case "aach", "aacp": return "HE-AAC"
        case "ac-3": return "AC3"
        case "ec-3": return "E-AC3"
        case ".mp3": return "MP3"
        case ".mp2": return "MP2"
        case "opus": return "Opus"
        case "alac": return "ALAC"
        case "dtsc", "dtsh", "dtsl": return "DTS"
        default: return s.trimmingCharacters(in: CharacterSet(charactersIn: " .")).uppercased()
        }
    }
}

/// Hàng nhãn thông số dạng viền mảnh.
struct StreamBadges: View {
    let info: StreamInfo

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Array(info.badges.enumerated()), id: \.offset) { i, label in
                let strong = i == 0 && info.height > 0     // nhãn chất lượng (FHD/HD/4K) nổi bật hơn
                Text(label)
                    .font(.system(size: 22, weight: strong ? .bold : .medium))
                    .foregroundStyle(strong ? Theme.accent : Color.white)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(strong ? Theme.accent : Color.white.opacity(0.4), lineWidth: 2)
                    )
            }
        }
    }
}
