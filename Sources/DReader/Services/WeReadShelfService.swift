import Foundation

/// 微信读书云端书架（个人互操作用途）。
/// 接口（社区项目通用，需登录 Cookie）：
///   GET https://i.weread.qq.com/shelf/sync?synckey=0&lectureSynckey=0
///     → { books: [ { bookId, title, author, cover, … } ], archive: […], … }
///   GET https://i.weread.qq.com/book/info?bookId=…
///     → { title, author, intro, cover, newRating, … }
/// 注意 -2010/-2012 均为登录态失效。
final class WeReadShelfService: @unchecked Sendable {
    static let shared = WeReadShelfService()

    private static let apiBase = "https://i.weread.qq.com"
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36 Edg/135.0.0.0"

    struct ShelfBook: Identifiable, Equatable {
        let bookId: String
        let title: String
        let author: String
        let cover: String
        var id: String { bookId }
    }

    enum ShelfError: LocalizedError {
        case notLoggedIn
        case authExpired(Int)
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .notLoggedIn: return "尚未登录微信读书，请先扫码登录"
            case .authExpired(let code): return "微信读书登录态已失效（\(code)），请重新扫码登录"
            case .http(let code): return "微信读书书架请求 HTTP \(code)"
            }
        }
    }

    private func get(_ path: String, query: [String: String] = [:]) async throws -> Data {
        guard WeReadContentService.shared.hasCookie else { throw ShelfError.notLoggedIn }
        var components = URLComponents(string: Self.apiBase + path)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: components.url!)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://weread.qq.com/", forHTTPHeaderField: "Origin")
        request.setValue("https://weread.qq.com/", forHTTPHeaderField: "Referer")
        request.setValue(WeReadContentService.shared.cookie, forHTTPHeaderField: "Cookie")
        request.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse else { throw ShelfError.http(-1) }
        guard (200..<300).contains(http.statusCode) else { throw ShelfError.http(http.statusCode) }
        // 登录态诊断：errCode -2010/-2012 统一判失效
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let errCode = (obj["errCode"] ?? obj["errcode"]) as? Int, errCode != 0 {
            throw ShelfError.authExpired(errCode)
        }
        return data
    }

    /// 拉取全量书架。仅保留图书（过滤有声书/公众号：无 bookId 或 bookId 前缀 MP_WXS_）。
    func fetchShelf() async throws -> [ShelfBook] {
        let data = try await get("/shelf/sync", query: ["synckey": "0", "lectureSynckey": "0"])
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawBooks = obj["books"] as? [[String: Any]]
        else { return [] }
        return rawBooks.compactMap { raw in
            guard let bookId = raw["bookId"] as? String, !bookId.isEmpty,
                  !bookId.hasPrefix("MP_WXS_")
            else { return nil }
            return ShelfBook(
                bookId: bookId,
                title: (raw["title"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                author: (raw["author"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                cover: raw["cover"] as? String ?? ""
            )
        }
        .filter { !$0.title.isEmpty }
    }

    /// 封面 URL 升清（t7→t9 与 KOReader normalize_cover_url 一致）
    static func highResCover(_ url: String) -> String {
        guard !url.isEmpty else { return url }
        var result = url
        if let range = result.range(of: "/t\\d+_", options: .regularExpression) {
            result.replaceSubrange(range, with: "/t9_")
        }
        if let range = result.range(of: "/s_") {
            result.replaceSubrange(range, with: "/t9_")
        }
        return result
    }
}
