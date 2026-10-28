import AppKit

/// 书架封面缓存：磁盘解码一次、NSCache 常驻，滚动时零解码开销。
/// EPUB 封面常是 1000×1500 大图，同步解码一张几十毫秒——书架书项
/// 此前在 body 计算属性里每次重算都重新读盘解码，滑动必掉帧。
final class CoverImageCache: @unchecked Sendable {
    static let shared = CoverImageCache()

    private let cache = NSCache<NSString, NSImage>()
    /// 同一 URL 的在途加载去重（并发滚动时同一封面只解码一次）
    private var inflight: Set<String> = []
    private let lock = NSLock()

    private init() {
        // 封面解码后常驻内存的合理上限：约 60 张 140×204 显示尺寸所需的原图内存
        cache.countLimit = 60
    }

    /// 同步取缓存；未命中返回 nil（视图随即显示占位封面）
    func cachedImage(for url: URL) -> NSImage? {
        cache.object(forKey: url.path as NSString)
    }

    /// 后台解码 + 缓存。完成在主线程回调（nil = 解码失败）。
    /// 同一 URL 并发请求去重；重复请求完成前只排最早的一次。
    func loadImage(for url: URL, completion: @escaping (NSImage?) -> Void) {
        let path = url.path
        if let hit = cache.object(forKey: path as NSString) {
            completion(hit)
            return
        }
        lock.lock()
        let alreadyInflight = inflight.contains(path)
        if !alreadyInflight { inflight.insert(path) }
        lock.unlock()
        guard !alreadyInflight else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = NSImage(contentsOf: url)
            if let image {
                self?.cache.setObject(image, forKey: path as NSString)
            }
            self?.lock.lock()
            self?.inflight.remove(path)
            self?.lock.unlock()
            DispatchQueue.main.async {
                completion(image)
            }
        }
    }
}
