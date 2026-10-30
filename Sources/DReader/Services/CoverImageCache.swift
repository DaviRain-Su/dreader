import AppKit
import ImageIO

/// 后台生成封面缩略图，并通知等待同一资源的全部书项。
final class CoverImageCache: @unchecked Sendable {
    static let shared = CoverImageCache()

    /// nonisolated(unsafe) 结果盒：写入点只在主 actor 回调内、读取点只在主 actor
    /// 的 image(for:) 内，续体恢复建立先行关系，无数据竞争。
    private final class ResultBox: @unchecked Sendable {
        nonisolated(unsafe) var image: NSImage?
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

    /// async 入口：续体只传"已就绪"信号（Void），图像经结果盒取回——
    /// resume(returning:) 的参数是 sending，主 actor 隔离的 NSImage 进不去。
    @MainActor
    func image(for url: URL) async -> NSImage? {
        let box = ResultBox()
        await withCheckedContinuation { continuation in
            loadImage(for: url) { image in
                // 回调在主 actor 执行；图像存入盒后只跨隔离域传 Void 信号。
                box.image = image
                continuation.resume()
            }
        }
        return box.image
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
