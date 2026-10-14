import AVFoundation
import SwiftUI
import UIKit

/// Trình phát dùng chung cho khung xem trước và toàn màn hình (AVPlayer, hỗ trợ HLS .m3u8, MP4…).
/// Vào toàn màn hình từ khung xem trước thì kênh chạy tiếp, không phải tải lại.
@MainActor
final class PlayerEngine: ObservableObject {
    let player = AVPlayer()

    @Published private(set) var buffering = false
    @Published private(set) var error: String?
    @Published private(set) var info: StreamInfo?
    @Published private(set) var currentURL: String?

    /// Xem trước: giới hạn 854×480 cho nhẹ
    private static let previewSize = CGSize(width: 854, height: 480)
    private var previewMode = true
    private var suspended = false

    private var timeObserver: NSKeyValueObservation?
    private var itemObservers: [NSKeyValueObservation] = []
    private var notes: [NSObjectProtocol] = []
    private var retryTask: Task<Void, Never>?
    private var infoTask: Task<Void, Never>?

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        timeObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] p, _ in
            let waiting = p.timeControlStatus == .waitingToPlayAtSpecifiedRate
            Task { @MainActor [weak self] in self?.setBuffering(waiting) }
        }
    }

    private func setBuffering(_ waiting: Bool) {
        let value = waiting && currentURL != nil
        if buffering != value { buffering = value }
    }

    // MARK: Điều khiển

    func play(_ url: String) {
        currentURL = url
        error = nil
        info = nil
        retryTask?.cancel()
        startItem()
    }

    func stop() {
        currentURL = nil
        retryTask?.cancel()
        infoTask?.cancel()
        clearItemObservers()
        player.replaceCurrentItem(with: nil)
        buffering = false
        error = nil
        info = nil
    }

    func setPreviewMode(_ on: Bool) {
        previewMode = on
        player.currentItem?.preferredMaximumResolution = on ? Self.previewSize : .zero
    }

    /// App xuống nền (bấm Home / TV tắt): dừng tiếng.
    func suspend() {
        guard currentURL != nil else { return }
        suspended = true
        retryTask?.cancel()
        player.pause()
    }

    /// Quay lại app: kênh live thì nạp lại để về điểm trực tiếp.
    func resume() {
        guard suspended else { return }
        suspended = false
        if currentURL != nil { startItem() }
    }

    // MARK: Nội bộ

    private func clearItemObservers() {
        itemObservers.forEach { $0.invalidate() }
        itemObservers.removeAll()
        notes.forEach { NotificationCenter.default.removeObserver($0) }
        notes.removeAll()
    }

    private func startItem() {
        guard let raw = currentURL else { return }
        guard let parsed = StreamURL.parse(raw) else {
            error = "Link kênh không hợp lệ"
            return
        }
        clearItemObservers()

        let asset = AVURLAsset(url: parsed.url, options: ["AVURLAssetHTTPHeaderFieldsKey": parsed.headers])
        let item = AVPlayerItem(asset: asset)
        item.preferredMaximumResolution = previewMode ? Self.previewSize : .zero
        let itemID = ObjectIdentifier(item)

        itemObservers.append(item.observe(\.status, options: [.new]) { [weak self] it, _ in
            let status = it.status
            let message = it.error?.localizedDescription
            Task { @MainActor [weak self] in self?.statusChanged(itemID, status, message) }
        })

        let nc = NotificationCenter.default
        notes.append(nc.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] n in
            let err = (n.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
            Task { @MainActor [weak self] in self?.fail(itemID, "Mất luồng (\(err ?? "lỗi mạng"))") }
        })
        notes.append(nc.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            // Kênh live mà "hết" nghĩa là luồng bị ngắt: thử lại
            Task { @MainActor [weak self] in self?.fail(itemID, "Luồng bị ngắt") }
        })

        player.replaceCurrentItem(with: item)
        player.play()
        buffering = true
        startInfoPolling(item)
    }

    private func isCurrent(_ id: ObjectIdentifier) -> Bool {
        guard let item = player.currentItem else { return false }
        return ObjectIdentifier(item) == id
    }

    private func statusChanged(_ id: ObjectIdentifier, _ status: AVPlayerItem.Status, _ message: String?) {
        guard isCurrent(id) else { return }
        switch status {
        case .readyToPlay:
            error = nil
        case .failed:
            fail(id, "Không phát được kênh này (\(message ?? "lỗi không rõ"))")
        default:
            break
        }
    }

    /// Lỗi mạng / mất luồng: tự thử lại sau 5 giây
    private func fail(_ id: ObjectIdentifier, _ message: String) {
        guard isCurrent(id), let url = currentURL else { return }
        error = message
        buffering = false
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, !Task.isCancelled, !self.suspended,
                  self.error != nil, self.currentURL == url else { return }
            self.startItem()
        }
    }

    /// Đọc thông số luồng: 1 giây/lần cho tới khi có, sau đó 4 giây/lần (bitrate HLS có thể đổi).
    private func startInfoPolling(_ item: AVPlayerItem) {
        infoTask?.cancel()
        let id = ObjectIdentifier(item)
        infoTask = Task { [weak self] in
            var delay: UInt64 = 1
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                guard let self, !Task.isCancelled, self.isCurrent(id) else { return }
                if item.status == .readyToPlay, let fresh = await StreamInfo.read(from: item),
                   !Task.isCancelled, self.isCurrent(id), fresh != self.info {
                    self.info = fresh
                }
                delay = self.info == nil ? 1 : 4
            }
        }
    }
}

/// Lớp hiển thị video (AVPlayerLayer). Không bao giờ nhận focus, để phím remote không bị "nuốt".
struct VideoSurface: UIViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspect

    func makeUIView(context: Context) -> PlayerUIView {
        let v = PlayerUIView()
        v.backgroundColor = .black
        v.isUserInteractionEnabled = false
        v.playerLayer.player = player
        v.playerLayer.videoGravity = gravity
        return v
    }

    func updateUIView(_ v: PlayerUIView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
        v.playerLayer.videoGravity = gravity
    }

    static func dismantleUIView(_ v: PlayerUIView, coordinator: ()) {
        v.playerLayer.player = nil
    }

    final class PlayerUIView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        override var canBecomeFocused: Bool { false }
    }
}
