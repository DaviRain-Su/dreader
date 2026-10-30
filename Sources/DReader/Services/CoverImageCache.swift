import AppKit
import ImageIO

/// 后台生成封面缩略图，并通知等待同一资源的全部书项。
final class CoverImageCache: @unchecked Sendable {
    static let shared = CoverImageCache()

    /// 兑现 image(for:) 的续体：方法本身 @MainActor，NSImage 不跨隔离域直传。
    @MainActor
    private final class CoverImageWaiter: @unchecked Sendable {
        private let continuation: CheckedContinuation<NSImage?, Never>
        private var fulfilled = false

        init(_ continuation: CheckedContinuation<NSImage?, Never>) {
            self.continuation = continuation
        }

        func fulfill(_ image: NSImage?) {
            guard !fulfilled else { return }
            fulfilled = true
            continuation.resume(returning: image)
        }
    }

    private typealias Completion = @MainActor @Sendable (NSImage?) -> Void
    private let cache = NSCache<NSString, NSImage>()
    private var inflight: [String: [Completion]] = [:]
    private let lock = NSLock()

    private init() {
        cache.countLimit = 60
        cache.totalCostLimit = 60 * 1024 * 1024
    }

    private func cacheKey(for url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return "\(url.path)-\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)-\(values?.fileSize ?? 0)"
    }

    func cachedImage(for url: URL) -> NSImage? {
        cache.object(forKey: cacheKey(for: url) as NSString)
    }

    /// async 入口：经 @MainActor 持有盒兑现续体，NSImage 全程留在主 actor
    /// 隔离内（@Sendable 闭包参数直接传 sending 会触发 Swift 6.0 竞争检查）。
    @MainActor
    func image(for url: URL) async -> NSImage? {
        await withCheckedContinuation { continuation in
            let waiter = CoverImageWaiter(continuation)
            loadImage(for: url) { image in
                waiter.fulfill(image)
            }
        }
    }

    @MainActor
    func loadImage(for url: URL, completion: @escaping @MainActor @Sendable (NSImage?) -> Void) {
        let key = cacheKey(for: url)
        if let hit = cache.object(forKey: key as NSString) {
            completion(hit)
            return
        }
        lock.lock()
        if inflight[key] != nil {
            inflight[key]?.append(completion)
            lock.unlock()
            return
        }
        inflight[key] = [completion]
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 512,
                kCGImageSourceShouldCacheImmediately: true
            ]
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)
            let bitmap = source.flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, options as CFDictionary) }
            let image = bitmap.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            if let image, let bitmap {
                cache.setObject(image, forKey: key as NSString, cost: bitmap.bytesPerRow * bitmap.height)
            }
            lock.lock()
            let callbacks = inflight.removeValue(forKey: key) ?? []
            lock.unlock()
            DispatchQueue.main.async {
                for callback in callbacks { callback(image) }
            }
        }
    }
}
