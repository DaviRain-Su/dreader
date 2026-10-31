//
//  RankingServiceTests.swift
//  DReaderTests
//
//  榜单目录的测试：
//  - URLProtocol fixture 全量截获（绝不退回真实网络，照 OPDSSecurityTests 样板）；
//  - 微信网页榜单 JSON 宽松解析（缺字段丢行）；
//  - 静态快照（豆瓣/诺奖/布克/普利策）全量健全性；
//  - TTL 纯函数与评分归一。
//

import XCTest
@testable import DReader

final class RankingServiceTests: XCTestCase {

    // MARK: - Fixture（截获全部请求）

    private final class RankingFixtureProtocol: URLProtocol {
        static let guarded = NSLock()
        nonisolated(unsafe) private static var responses: [String: (status: Int, json: String)] = [:]
        nonisolated(unsafe) private static var recorded: [URLRequest] = []

        static func register(path: String, status: Int, json: String) {
            guarded.lock(); defer { guarded.unlock() }
            responses[path] = (status, json)
        }

        static func recordedRequests() -> [URLRequest] {
            guarded.lock(); defer { guarded.unlock() }
            return recorded
        }

        static func reset() {
            guarded.lock(); defer { guarded.unlock() }
            responses = [:]
            recorded = []
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func stopLoading() {}

        override func startLoading() {
            let url = request.url!
            Self.guarded.lock()
            Self.recorded.append(request)
            let match = Self.responses.first { url.path.contains($0.key) }
            Self.guarded.unlock()

            guard let (_, value) = match else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            let response = HTTPURLResponse(
                url: url, statusCode: value.status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(value.json.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    private var madeDomains: [String] = []

    private func makeService() -> RankingService {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [RankingFixtureProtocol.self]
        let suite = "test_rankings_\(UUID().uuidString)"
        madeDomains.append(suite)
        let prefs = UserDefaults(suiteName: suite)!
        return RankingService(configuration: cfg, preferences: prefs)
    }

    override func tearDown() {
        RankingFixtureProtocol.reset()
        for domain in madeDomains {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        madeDomains.removeAll()
        super.tearDown()
    }

    private func wereadCatalog(_ id: String = "weread.rising") -> RankingCatalog {
        RankingsRegistry.allCatalogs.first { $0.id == id }!
    }

    // MARK: - 微信榜单解析

    private let wereadFixtureJSON = """
    {"books": [
        {"bookInfo": {"title": "我弥留之际", "bookId": "abc123", "author": "[美] 威廉·福克纳",
                      "cover": "i.wereadqq.com/file/0/x/a.jpg", "intro": "一把雪茄，一场关于人性的长谈"},
         "readingCount": 51000, "ratingScore": 892},
        {"bookInfo": {"title": "无名书", "bookId": "b2", "author": "", "cover": "", "intro": ""},
         "readingCount": 12},
        {"readingCount": 999}
    ], "totalCount": 40}
    """

    func testWereadBoardDecodeKeepsGoodRowsDropsBadRows() async throws {
        RankingFixtureProtocol.register(path: "/web/bookListInCategory", status: 200, json: wereadFixtureJSON)
        let service = makeService()

        let result = try await service.load(catalog: wereadCatalog())

        XCTAssertEqual(result.books.count, 2)
        XCTAssertEqual(result.isStale, false)
        XCTAssertNotNil(result.fetchedAt)

        let first = try XCTUnwrap(result.books.first)
        XCTAssertEqual(first.rank, 1)
        XCTAssertEqual(first.wereadBookId, "abc123")
        XCTAssertEqual(first.title, "我弥留之际")
        XCTAssertEqual(first.rating, 8.9)                 // 0-1000 档归一
        XCTAssertEqual(first.readersText, "5.1万人在读")
        XCTAssertEqual(first.language, .zh)
        XCTAssertEqual(first.externalURL?.path, "/web/bookDetail/abc123")
        XCTAssertNotNil(first.coverURL)

        let second = try XCTUnwrap(result.books.last)
        XCTAssertEqual(second.author, "佚名")
        XCTAssertNil(second.summary)

        // 缺 bookInfo 的行被丢弃（b2 行保留、光杆行不进结果）
        XCTAssertTrue(result.books.contains { $0.wereadBookId == "b2" })
        XCTAssertEqual(result.books.filter { $0.wereadBookId == nil }.count, 0)

        // 请求带浏览器 UA 与 maxIndex 0 分页参数
        let request = try XCTUnwrap(RankingFixtureProtocol.recordedRequests().first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent")?.contains("Chrome"), true)
        XCTAssertTrue(request.url?.query?.contains("maxIndex=0") == true)
        XCTAssertTrue(request.url?.query?.contains("rank=1") == true)
    }

    func testLoadMorePaginatesAndStopsAtEnd() async throws {
        RankingFixtureProtocol.register(path: "/web/bookListInCategory", status: 200, json: wereadFixtureJSON)
        let service = makeService()
        let catalog = wereadCatalog()

        _ = try await service.load(catalog: catalog)

        // totalCount=40：第二页 maxIndex=20 可拉
        let more = try await service.loadMore(catalog: catalog)
        XCTAssertEqual(more?.count, 2)
        let secondRequest = try XCTUnwrap(RankingFixtureProtocol.recordedRequests().last)
        XCTAssertTrue(secondRequest.url?.query?.contains("maxIndex=20") == true)

        // pages=2, total=40 → 已到头
        let exhausted = try await service.loadMore(catalog: catalog)
        XCTAssertNil(exhausted)
        XCTAssertEqual(RankingFixtureProtocol.recordedRequests().count, 2)
    }

    func testFreshForceRefetchSharesInFlight() async throws {
        RankingFixtureProtocol.register(path: "/web/bookListInCategory", status: 200, json: wereadFixtureJSON)
        let service = makeService()
        let catalog = wereadCatalog()

        // 同一目录并发请求只发一次 HTTP（in-flight 合流）
        async let a = service.load(catalog: catalog, force: true)
        async let b = service.load(catalog: catalog, force: true)
        _ = try await (a, b)
        XCTAssertEqual(RankingFixtureProtocol.recordedRequests().count, 1)
    }

    // MARK: - 评分归一

    func testNormalizedRating() {
        XCTAssertEqual(RankingService.normalizedRating(["ratingScore": 9.4]), 9.4)
        XCTAssertEqual(RankingService.normalizedRating(["newRating": 92]), 9.2)
        XCTAssertEqual(RankingService.normalizedRating(["ratingScore": 892]), 8.9)
        XCTAssertNil(RankingService.normalizedRating(["foo": 1]))
        XCTAssertNil(RankingService.normalizedRating(["ratingScore": 20_000]))
    }

    // MARK: - 静态快照健全性

    func testDoubanSnapshotIntegrity() {
        XCTAssertEqual(doubanTop250.count, 250)
        let ranks = Set(doubanTop250.map(\.rank))
        XCTAssertEqual(ranks.count, 250)
        XCTAssertEqual(ranks, Set(1...250))
        for book in doubanTop250 {
            XCTAssertFalse(book.title.isEmpty)
            XCTAssert(book.rating == nil || (0...10).contains(book.rating!),
                      "评分越界：\(book.title)")
            if let url = book.externalURL {
                XCTAssertEqual(url.host, "book.douban.com")
                XCTAssertTrue(url.absoluteString.hasPrefix("https"), "\(book.title) 外链非 https")
            } else {
                XCTFail("豆瓣条目缺外链：\(book.title)")
            }
            // v2:封面直链(m 尺码)与 ISBN
            guard let cover = book.coverURL else {
                XCTFail("豆瓣条目缺封面：\(book.title)")
                continue
            }
            XCTAssertTrue(cover.host?.contains("doubanio") == true, "\(book.title) 封面 host 异常")
            XCTAssertTrue(cover.absoluteString.contains("/view/subject/m/"),
                          "\(book.title) 封面非 m 尺码")
            if let isbn = book.isbn {
                XCTAssertTrue((10...13).contains(isbn.count) && Int(isbn) != nil,
                              "ISBN 异常：\(book.title) \(isbn)")
            }
        }
        // 头部钉住：榜单招牌前三仍是这些书（快照换版时提醒校对）
        XCTAssertEqual(doubanTop250[0].title, "红楼梦")
        XCTAssertEqual(doubanTop250[1].title, "活着")
    }

    func testCuratedSnapshotsIntegrity() {
        let lists: [String: [RankingBook]] = [
            "nobel.literature": nobelWorldClassics,
            "booker.prize": bookerWinners,
            "pulitzer.fiction": pulitzerFictionWinners
        ]
        for (catalogID, books) in lists {
            XCTAssertTrue(books.count >= 50, "\(catalogID) 条目过少")
            XCTAssertEqual(Set(books.map(\.rank)), Set(1...books.count), "\(catalogID) 排名断裂")
            for book in books {
                XCTAssertFalse(book.title.isEmpty)
                XCTAssertNotNil(book.externalURL, "\(catalogID) 缺外链：\(book.title)")
                XCTAssertNotNil(book.honor, "\(catalogID) 缺奖项信息：\(book.title)")
                if let gid = book.gutenbergID {
                    XCTAssertNotNil(Int(gid), "gutenbergID 非数字：\(book.title) (\(gid))")
                }
            }
        }
        // 目录注册表与静态数据一一对应
        for catalog in RankingsRegistry.allCatalogs where !catalog.isLive {
            XCTAssertNotNil(RankingsRegistry.staticBooks(catalogID: catalog.id),
                            "目录 \(catalog.id) 没有对应静态数据")
        }
        // 封面覆盖表的键都必须落在奖项书目里(防止生成脚本错键静默失落)
        let allCurated = Set((nobelWorldClassics + bookerWinners + pulitzerFictionWinners).map(\.id))
        for kid in RankingCoverOverrides.ids.keys {
            XCTAssertTrue(allCurated.contains(kid), "覆盖表键不存在于奖项书目:\(kid)")
        }
        // 奖项榜 89% 以上条款有封面(gutenberg/OL 覆盖;缺的以字牌兜底)
        let withCover = (nobelWorldClassics + bookerWinners + pulitzerFictionWinners)
            .filter { $0.coverURL != nil }.count
        let total = nobelWorldClassics.count + bookerWinners.count + pulitzerFictionWinners.count
        XCTAssertGreaterThan(Double(withCover) / Double(total), 0.85,
                             "奖项榜封面覆盖率不足:\(withCover)/\(total)")
    }

    // MARK: - TTL 与 slug

    func testStalenessPolicy() {
        let weread = wereadCatalog()                       // refreshInterval 6h
        let douban = RankingsRegistry.allCatalogs.first { $0.id == "douban.top250" }!
        let now = Date()

        XCTAssertFalse(RankingCachePolicy.isStale(
            fetchedAt: now.addingTimeInterval(-(5 * 3600 + 59 * 60)), catalog: weread, now: now))
        XCTAssertTrue(RankingCachePolicy.isStale(
            fetchedAt: now.addingTimeInterval(-(6 * 3600 + 60)), catalog: weread, now: now))
        // 静态目录无 TTL，永不过期
        XCTAssertFalse(RankingCachePolicy.isStale(
            fetchedAt: now.addingTimeInterval(-100 * 86400), catalog: douban, now: now))
    }

    func testSlugExtraction() {
        XCTAssertEqual(RankingService.slug(of: "weread.rising"), "rising")
        XCTAssertEqual(RankingService.slug(of: "weread.newbook"), "newbook")
        XCTAssertEqual(RankingService.slug(of: "weread.all"), "all")
        XCTAssertNil(RankingService.slug(of: "douban.top250"))
        XCTAssertNil(RankingService.slug(of: "nobel.literature"))
    }
}
