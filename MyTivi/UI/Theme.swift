import SwiftUI

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

/// Bảng màu giống bản Android
enum Theme {
    static let bg = Color(hex: 0x0B1220)
    static let accent = Color(hex: 0x38BDF8)
    static let dim = Color(hex: 0x94A3B8)
    static let focusBg = Color(hex: 0x1E3A5F)
    static let error = Color(hex: 0xF87171)
    static let gold = Color(hex: 0xFACC15)
    static let line = Color.white.opacity(0.2)

    static let cellEmpty = Color(hex: 0x111B2E)
    static let cellLive = Color(hex: 0x24406B)
    static let cellNormal = Color(hex: 0x182640)
}

enum Fmt {
    private static let hm: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
    private static let dayShort: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "vi_VN")
        f.dateFormat = "EEE, dd/MM  HH:mm"
        return f
    }()
    private static let dayLong: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "vi_VN")
        f.dateFormat = "EEEE, dd/MM"
        return f
    }()

    static func hhmm(_ t: TimeInterval) -> String { hm.string(from: Date(timeIntervalSince1970: t)) }
    static func hhmm(_ d: Date) -> String { hm.string(from: d) }
    static func shortDay(_ t: TimeInterval) -> String { dayShort.string(from: Date(timeIntervalSince1970: t)) }
    static func longDay(_ t: TimeInterval) -> String { dayLong.string(from: Date(timeIntervalSince1970: t)) }

    static var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(v) (\(b))"
    }
}

/// Giờ hiện tại, cập nhật mỗi 30 giây (để thanh tiến độ chương trình tự chạy).
@MainActor
final class Clock: ObservableObject {
    @Published private(set) var now = Date().timeIntervalSince1970
    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date().timeIntervalSince1970 }
        }
    }
}

/// Nút không có hiệu ứng focus của hệ thống (dùng cho vùng điều khiển tự vẽ: bảng lịch, trình phát).
struct BareButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

/// Mục trong danh sách/menu: tô nền + viền khi đang được focus (giống tvFocusable() bản Android).
struct TvRowButtonStyle: ButtonStyle {
    var padding = EdgeInsets(top: 14, leading: 22, bottom: 14, trailing: 22)

    func makeBody(configuration: Configuration) -> some View {
        Body(configuration: configuration, padding: padding)
    }

    private struct Body: View {
        let configuration: ButtonStyleConfiguration
        let padding: EdgeInsets
        @Environment(\.isFocused) private var focused

        var body: some View {
            configuration.label
                .padding(padding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(focused ? Theme.focusBg : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(focused ? Theme.accent : Color.clear, lineWidth: 3)
                )
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(.easeOut(duration: 0.12), value: focused)
        }
    }
}

/// Nút dạng "viên thuốc" cho màn hình Cài đặt.
struct TvPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Body(configuration: configuration)
    }

    private struct Body: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var focused

        var body: some View {
            configuration.label
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(focused ? Color.black : Color.white)
                .padding(.horizontal, 40)
                .padding(.vertical, 18)
                .background(Capsule().fill(focused ? Theme.accent : Theme.focusBg))
                .scaleEffect(focused ? 1.06 : 1)
                .animation(.easeOut(duration: 0.15), value: focused)
        }
    }
}

/// Thanh tiến độ mảnh
struct ProgressLine: View {
    let value: Double
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18))
                Capsule().fill(Theme.accent).frame(width: geo.size.width * value)
            }
        }
        .frame(height: height)
    }
}
