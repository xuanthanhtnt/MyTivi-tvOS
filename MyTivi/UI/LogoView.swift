import SwiftUI
import UIKit

/// Bộ nhớ đệm logo kênh (AsyncImage không giữ cache, lướt bảng lịch sẽ tải lại liên tục).
@MainActor
final class ImageCache {
    static let shared = ImageCache()

    private let cache = NSCache<NSString, UIImage>()
    private var tasks: [String: Task<UIImage?, Never>] = [:]
    private var failed = Set<String>()

    private init() { cache.countLimit = 600 }

    func cached(_ url: String) -> UIImage? { cache.object(forKey: url as NSString) }

    func load(_ url: String) async -> UIImage? {
        if let img = cached(url) { return img }
        if failed.contains(url) { return nil }
        if let t = tasks[url] { return await t.value }
        let task = Task.detached(priority: .utility) { () -> UIImage? in
            guard let u = URL(string: url),
                  let result = try? await Http.session.data(from: u),
                  let img = UIImage(data: result.0) else { return nil }
            return img.preparingThumbnail(of: CGSize(width: 160, height: 160)) ?? img
        }
        tasks[url] = task
        let img = await task.value
        tasks[url] = nil
        if let img { cache.setObject(img, forKey: url as NSString) } else { failed.insert(url) }
        return img
    }
}

struct LogoView: View {
    let url: String
    let size: CGFloat
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .task(id: url) {
            image = url.isEmpty ? nil : ImageCache.shared.cached(url)
            if image == nil && !url.isEmpty {
                image = await ImageCache.shared.load(url)
            }
        }
    }
}
