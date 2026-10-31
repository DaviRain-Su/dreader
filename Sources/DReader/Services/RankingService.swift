//
//  RankingService.swift
//  DReader
//
//  榜单拉取与缓存：
//  - 静态快照（豆瓣 Top250 / 国际奖项）同步返回内置常量，不走网络；
//  - 微信读书网页榜单实时拉取（weread.qq.com/web/bookListInCategory/{slug}），无需登录 key；
//  - UserDefaults + JSON 落盘（照 dreader.opds.sources 先例），失败回退陈缓存；
//  - NSLock 节流 + in-flight 合流（防止快速切换左栏重复打请求）。
//

import Foundation

/// 榜单拉取结果
struct RankingFetchResult: Sendable {
    let books: [RankingBook]
    /// 数据实际抓取时间；静态快照为 nil
    let fetchedAt: Date?
    /// true = 网络失败时回退的陈缓存
    let isStale: Bool
}

enum RankingError: LocalizedError {
    case http(Int)
    case decode
    case unsupportedCatalog

    var errorDescription: String? {
        switch self {
        case .http(let code): return "榜单拉取失败（HTTP \(code)）"
        case .decode: return "榜单数据解析失败，请稍后重试"
        case .unsupportedCatalog: return "该榜单不支持在线刷新（内置快照）"
        }
    }
}

/// 缓存新鲜度纯函数（可单测）
enum RankingCachePolicy {
    /// fetchedAt 距 now 超过 catalog.refreshInterval 视为过期；静态目录（无 TTL）永不过期
    static func isStale(fetchedAt: Date, catalog: RankingCatalog, now: Date = Date()) -> Bool {
        guard let interval = catalog.refreshInterval else { return false }
        return now.timeIntervalSince(fetchedAt) >= interval
    }
}

/// 单榜缓存条目：整组书目一次编码 + 抓取时间
struct RankingCacheEntry: Codable, Sendable {
    let payload: Data
    let fetchedAt: Date
}

final class RankingService: @unchecked Sendable {
    static let shared = RankingService()

    private static let webBase = "https://weread.qq.com"
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36"
    private static let cacheKey = "dreader.rankings.cache"
    private static let throttleInterval: TimeInterval = 0.8    // 微信网页接口礼貌间隔
    private static let pageSize = 20                           // bookListInCategory 每页 20

    private let session: URLSession
    private var prefs: UserDefaults
    private let lock = NSLock()
    private var cache: [String: RankingCacheEntry] = [:]
    private var inFlight: [String: Task<RankingFetchResult, Error>] = [:]
    private var lastRequestTime = Date.distantPast
    private var pagesLoaded: [String: Int] = [:]               // catalogID → 已拉页数
    private var totalBooks: [String: Int] = [:]                // catalogID → totalCount

    init(configuration: URLSessionConfiguration = .default, preferences: UserDefaults = .standard) {
        let cfg = (configuration.copy() as? URLSessionConfiguration) ?? configuration
        cfg.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        session = URLSession(configuration: cfg)
        prefs = preferences
        if let raw = prefs.data(forKey: Self.cacheKey),
           let decoded = try? JSONDecoder().decode([String: RankingCacheEntry].self, from: raw),
           decoded.isEmpty == false {
            cache = decoded
        }
    }

    // MARK: - 目录

    func catalogs() -> [RankingCatalog] { RankingsRegistry.allCatalogs }

    // MARK: - 主入口

    /// 拉取一个榜单：静态快照同步返回；live 目录走「缓存 → 网络 → 失败回退陈缓存」。
    func load(catalog: RankingCatalog, force: Bool = false) async throws -> RankingFetchResult {
        guard catalog.isLive else {
            guard let books = RankingsRegistry.staticBooks(catalogID: catalog.id) else {
                throw RankingError.unsupportedCatalog
            }
            return RankingFetchResult(books: books, fetchedAt: nil, isStale: false)
        }

        if !force, let (books, at) = cachedBooks(catalog) {
            return RankingFetchResult(books: books, fetchedAt: at, isStale: false)
        }

        let id = catalog.id
        // in-flight 合流：同目录并发请求共享同一 Task（CoverImageCache 同款范式）；
        // 查询与入队必须在一个锁块里完成，避免两个调用方同时 spawn
        let existing: Task<RankingFetchResult, Error>? = lock.withLockBlock { () -> Task<RankingFetchResult, Error>? in
            if let existing = inFlight[id] { return existing }
            let task = Task<RankingFetchResult, Error> { [weak self] in
                guard let self else { throw RankingError.unsupportedCatalog }
                defer { self.clearInFlight(catalogID: id) }
                do {
                    let page = try await self.fetchWereadBoard(catalog: catalog, page: 1)
                    self.setPagesLoaded(catalogID: id, pages: 1, totalCount: page.totalCount)
                    self.storeCache(catalogID: id, books: page.books)
                    return RankingFetchResult(books: page.books, fetchedAt: Date(), isStale: false)
                } catch {
                    if let (books, at) = self.cachedBooks(catalog) {
                        return RankingFetchResult(books: books, fetchedAt: at, isStale: true)
                    }
                    throw error
                }
            }
            inFlight[id] = task
            return task
        }
        guard let existing else { throw RankingError.unsupportedCatalog }
        return try await existing.value
    }

    /// 微信榜「加载更多」：按 20/页递增 maxIndex；末页或非 live 目录返回 nil。
    func loadMore(catalog: RankingCatalog) async throws -> [RankingBook]? {
        guard catalog.isLive else { return nil }
        let (pages, total) = lock.withLockBlock {
            (pagesLoaded[catalog.id] ?? 1, totalBooks[catalog.id] ?? 0)
        }
        guard total <= 0 || pages * Self.pageSize < total else { return nil }
        let page = try await fetchWereadBoard(catalog: catalog, page: pages + 1)
        setPagesLoaded(catalogID: catalog.id, pages: pages + 1, totalCount: page.totalCount)
        return page.books.isEmpty ? nil : page.books
    }

    /// UI 显示「数据截至 X」用
    func lastFetchedAt(catalogID: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return cache[catalogID]?.fetchedAt
    }

    // MARK: - 微信网页榜单

    private struct WereadBoardPage {
        let books: [RankingBook]
        let totalCount: Int
    }

    static func slug(of catalogId: String) -> String? {
        // catalogID "weread.rising" → slug "rising"
        guard catalogId.hasPrefix("weread.") else { return nil }
        return String(catalogId.dropFirst("weread.".count))
    }

    private func fetchWereadBoard(catalog: RankingCatalog, page: Int) async throws -> WereadBoardPage {
        guard let slug = Self.slug(of: catalog.id) else { throw RankingError.unsupportedCatalog }
        var components = URLComponents(string: Self.webBase + "/web/bookListInCategory/" + slug)!
        components.queryItems = [
            URLQueryItem(name: "rank", value: "1"),
            URLQueryItem(name: "maxIndex", value: String((page - 1) * Self.pageSize)),
            URLQueryItem(name: "wtheme", value: "white")
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.webBase + "/", forHTTPHeaderField: "Referer")

        // 节流：把下一个允许的时刻记入 lastRequestTime，本请求等待差额（WeReadContentService 同款）
        let wait: TimeInterval = lock.withLockBlock {
            let w = lastRequestTime.addingTimeInterval(Self.throttleInterval).timeIntervalSinceNow
            lastRequestTime = Date().addingTimeInterval(max(0, w))
            return w
        }
        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }

        let (data, resp) = try await session.data(for: request)
        guard let http = resp as? HTTPURLResponse else { throw RankingError.http(-1) }
        guard (200..<300).contains(http.statusCode) else { throw RankingError.http(http.statusCode) }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawBooks = obj["books"] as? [[String: Any]]
        else { throw RankingError.decode }

        let totalCount = obj["totalCount"] as? Int ?? rawBooks.count
        let baseRank = (page - 1) * Self.pageSize
        var seen = Set<String>()
        let books = rawBooks.enumerated().compactMap { idx, raw -> RankingBook? in
            guard let info = raw["bookInfo"] as? [String: Any],
                  let bookId = info["bookId"] as? String, !bookId.isEmpty,
                  !seen.contains(bookId)
            else { return nil }
            seen.insert(bookId)
            let title = (info["title"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { return nil }
            let author = (info["author"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let intro = (info["intro"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let coverPath = (info["cover"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let coverURL: URL?
            if coverPath.isEmpty {
                coverURL = nil
            } else if coverPath.hasPrefix("http") {
                coverURL = URL(string: coverPath)
            } else if coverPath.hasPrefix("//") {
                coverURL = URL(string: "https:" + coverPath)
            } else {
                coverURL = URL(string: "https://" + coverPath)
            }
            let encodedId = bookId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? bookId
            let rating = Self.normalizedRating(raw) ?? Self.normalizedRating(info)
            return RankingBook(
                id: "weread:\(bookId)",
                catalogID: catalog.id,
                rank: baseRank + idx + 1,
                title: title,
                author: author.isEmpty ? "佚名" : author,
                rating: rating,
                readersCount: raw["readingCount"] as? Int,
                language: .zh,
                coverURL: coverURL,
                summary: intro.isEmpty ? nil : intro,
                year: nil,
                externalURL: URL(string: Self.webBase + "/web/bookDetail/" + encodedId),
                wereadBookId: bookId,
                gutenbergID: nil,
                honor: nil, tag: nil, tintColors: nil
            )
        }
        return WereadBoardPage(books: books, totalCount: totalCount)
    }

    /// 评分归一：微信各字段 0-10 / 0-100 / 0-1000 三档都能收敛到 0...10
    static func normalizedRating(_ info: [String: Any]) -> Double? {
        guard let raw = (info["ratingScore"] ?? info["newRating"]) as? Double ??
                ((info["ratingScore"] ?? info["newRating"]) as? Int).map(Double.init)
        else { return nil }
        let v: Double
        if raw <= 10 { v = raw }
        else if raw <= 100 { v = raw / 10 }
        else if raw <= 1000 { v = raw / 100 }
        else { return nil }
        return (0...10).contains(v) ? (v * 10).rounded() / 10 : nil
    }

    // MARK: - 缓存

    private func cachedBooks(_ catalog: RankingCatalog) -> ([RankingBook], Date)? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = cache[catalog.id] else { return nil }
        if RankingCachePolicy.isStale(fetchedAt: entry.fetchedAt, catalog: catalog) { return nil }
        guard let books = try? JSONDecoder().decode([RankingBook].self, from: entry.payload) else {
            return nil
        }
        return (books, entry.fetchedAt)
    }

    private func storeCache(catalogID: String, books: [RankingBook]) {
        lock.lock()
        guard let payload = try? JSONEncoder().encode(books) else { lock.unlock(); return }
        let entry = RankingCacheEntry(payload: payload, fetchedAt: Date())
        cache[catalogID] = entry
        let toDisk = (try? JSONEncoder().encode(cache)) ?? Data()
        prefs.set(toDisk, forKey: Self.cacheKey)
        lock.unlock()
    }

    private func setPagesLoaded(catalogID: String, pages: Int, totalCount: Int) {
        lock.lock()
        pagesLoaded[catalogID] = pages
        totalBooks[catalogID] = totalCount
        lock.unlock()
    }

    private func clearInFlight(catalogID: String) {
        lock.lock()
        inFlight[catalogID] = nil
        lock.unlock()
    }
}

extension NSLock {
    /// withLock 风格包装（本文件内小用，避免依赖系统锁扩展的可用性）
    func withLockBlock<T>(_ block: () -> T) -> T {
        lock()
        defer { unlock() }
        return block()
    }
}
