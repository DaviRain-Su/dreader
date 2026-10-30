import Foundation
import SwiftUI

/// Tencent WeChat Reading API Gateway Service
/// Communicates with official WeChat Reading Agent Gateway (`https://i.weread.qq.com/api/agent/gateway`)
/// Provides notebook discovery, highlight retrieval, user thought extraction, and unified DReader synchronization.
@Observable
final class WeChatReadingService: @unchecked Sendable {
    static let shared = WeChatReadingService()

    private let gatewayURL = URL(string: "https://i.weread.qq.com/api/agent/gateway")!
    private let skillVersion = "1.0.5"

    // Storage Keys（api key 属凭据存 Keychain；时间戳留在 UserDefaults）
    private static let apiKeyAccount = "wechat_reading.api_key"
    private let apiKeyDefaultsKey = "dreader.wechat_reading.api_key"
    private let lastSyncTimeDefaultsKey = "dreader.wechat_reading.last_sync_time"

    // State
    var apiKey: String = ""
    var lastSyncDate: Date? = nil
    var isConnecting: Bool = false
    var isSyncing: Bool = false
    var syncProgress: Double = 0.0
    var syncStatusMessage: String = ""
    var notebooks: [WeChatNotebookItem] = []
    var totalNotebookCount: Int = 0
    var totalNoteCount: Int = 0
    var errorMessage: String? = nil

    init(loadPreferences: Bool = true) {
        guard loadPreferences else { return }
        // 1. Try saved key (Keychain，旧 UserDefaults 明文自动迁移)
        if let saved = KeychainStore.migrate(account: Self.apiKeyAccount, defaultsKey: apiKeyDefaultsKey), !saved.isEmpty {
            self.apiKey = saved
        } else if let envKey = ProcessInfo.processInfo.environment["WEREAD_API_KEY"], !envKey.isEmpty {
            // 2. Fallback to environment variable
            self.apiKey = envKey
        }

        if let dateInterval = UserDefaults.standard.object(forKey: lastSyncTimeDefaultsKey) as? Date {
            self.lastSyncDate = dateInterval
        }
    }

    func saveApiKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = trimmed
        _ = KeychainStore.write(Self.apiKeyAccount, value: trimmed)
    }

    func clearApiKey() {
        self.apiKey = ""
        KeychainStore.delete(Self.apiKeyAccount)
        UserDefaults.standard.removeObject(forKey: apiKeyDefaultsKey)
        self.notebooks.removeAll()
    }

    // MARK: - API Gateway Core Dispatcher
    private func postGateway<T: Decodable>(
        apiName: String,
        params: [String: Any] = [:],
        overrideKey: String? = nil
    ) async throws -> T {
        let key = (overrideKey ?? apiKey).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw WeChatAPIError.missingApiKey
        }

        var request = URLRequest(url: gatewayURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("DReader/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 25.0

        // Build Flattened Body: api_name, skill_version, and all business parameters at root
        var bodyDict: [String: Any] = [
            "api_name": apiName,
            "skill_version": skillVersion
        ]
        for (k, v) in params {
            bodyDict[k] = v
        }

        let jsonData = try JSONSerialization.data(withJSONObject: bodyDict, options: [])
        request.httpBody = jsonData

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WeChatAPIError.invalidResponse
        }

        // Check HTTP status code
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw WeChatAPIError.unauthorized
        }

        // Check if the JSON returned an errcode
        if let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let errcode = jsonObject["errcode"] as? Int, errcode != 0 {
                let errmsg = jsonObject["errmsg"] as? String ?? "未知错误 (代码: \(errcode))"
                throw WeChatAPIError.serverError(code: errcode, message: errmsg)
            }
        }

        let decoder = JSONDecoder()
        return try decoder.decode(T.self, from: data)
    }

    // MARK: - Test Connection
    func testConnection(testKey: String? = nil) async throws -> (bookCount: Int, noteCount: Int) {
        let keyToTest = testKey ?? apiKey
        let resp: WeChatNotebooksResponse = try await postGateway(
            apiName: "/user/notebooks",
            params: ["count": 5],
            overrideKey: keyToTest
        )

        let books = resp.totalBookCount ?? (resp.books?.count ?? 0)
        let notes = resp.totalNoteCount ?? 0
        return (books, notes)
    }

    // MARK: - Fetch All Notebooks (All books with notes)
    func fetchAllNotebooks() async throws -> [WeChatNotebookItem] {
        var allBooks: [WeChatNotebookItem] = []
        var lastSort: Int? = nil
        var hasMore = true
        var pageCount = 0

        while hasMore && pageCount < 15 {
            pageCount += 1
            var params: [String: Any] = ["count": 50]
            if let sort = lastSort {
                params["lastSort"] = sort
            }

            let resp: WeChatNotebooksResponse = try await postGateway(
                apiName: "/user/notebooks",
                params: params
            )

            if let totalBooks = resp.totalBookCount {
                self.totalNotebookCount = totalBooks
            }
            if let totalNotes = resp.totalNoteCount {
                self.totalNoteCount = totalNotes
            }

            if let books = resp.books, !books.isEmpty {
                allBooks.append(contentsOf: books)
                if let lastItem = books.last, let s = lastItem.sort {
                    lastSort = s
                }
            }

            hasMore = (resp.hasMore == 1)
        }

        self.notebooks = allBooks
        return allBooks
    }

    // MARK: - Fetch Book Highlights
    func fetchHighlights(for bookId: String) async throws -> (highlights: [WeChatBookmarkItem], chapters: [WeChatChapterInfo]) {
        let resp: WeChatBookmarkListResponse = try await postGateway(
            apiName: "/book/bookmarklist",
            params: ["bookId": bookId]
        )
        return (resp.updated ?? [], resp.chapters ?? [])
    }

    // MARK: - Fetch Book Reviews & Thoughts
    func fetchReviews(for bookId: String) async throws -> [WeChatReviewItem] {
        var allReviews: [WeChatReviewItem] = []
        var synckey: Int = 0
        var hasMore = true
        var pageCount = 0

        while hasMore && pageCount < 10 {
            pageCount += 1
            let resp: WeChatReviewListResponse = try await postGateway(
                apiName: "/review/list/mine",
                params: ["bookid": bookId, "synckey": synckey, "count": 50]
            )

            if let reviewContainers = resp.reviews {
                for c in reviewContainers {
                    allReviews.append(c.review)
                }
            }

            if let nextKey = resp.synckey, nextKey != synckey, resp.hasMore == 1 {
                synckey = nextKey
                hasMore = true
            } else {
                hasMore = false
            }
        }

        return allReviews
    }

    // MARK: - Convert WeChat Notes to DReader Highlights
    func convertToDReaderHighlights(
        notebook: WeChatNotebookItem,
        bookmarks: [WeChatBookmarkItem],
        chapters: [WeChatChapterInfo],
        reviews: [WeChatReviewItem],
        matchingLocalBook: EPUBBook?
    ) -> [Highlight] {
        let bookTitle = notebook.book.title
        let bookAuthor = notebook.book.author
        let wechatBookId = notebook.bookId

        // Stable UUID for book if no local book is open
        let targetBookId = matchingLocalBook?.id ?? deterministicUUID(for: "wechat_\(wechatBookId)")

        // Map chapter uid to chapter index and title
        var chapterMap: [Int: (index: Int, title: String)] = [:]
        for ch in chapters {
            chapterMap[ch.chapterUid] = (index: ch.chapterIdx, title: ch.title)
        }

        var results: [Highlight] = []
        var matchedReviewIds = Set<String>()

        // 1. Process Highlights from WeChat
        for bm in bookmarks {
            let markText = bm.markText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !markText.isEmpty else { continue }

            let chapterInfo = bm.chapterUid.flatMap { chapterMap[$0] }
            let chapterIdx = chapterInfo?.index ?? 0
            let chapterName = chapterInfo?.title ?? "全书标记"

            // Look for matching thoughts/review
            var noteContent: String? = nil
            if let matchedReview = reviews.first(where: { rev in
                !matchedReviewIds.contains(rev.reviewId) &&
                ((rev.abstract != nil && rev.abstract == markText) ||
                 (rev.range != nil && bm.range != nil && rev.range == bm.range))
            }) {
                noteContent = matchedReview.content
                matchedReviewIds.insert(matchedReview.reviewId)
            }

            let colorHex = mapWeChatColor(bm.colorStyle)
            let createdDate = Date(timeIntervalSince1970: bm.createTime)

            let highlight = Highlight(
                id: deterministicUUID(for: "wechat_bm_\(wechatBookId)_\(bm.bookmarkId)"),
                bookId: targetBookId,
                bookTitle: bookTitle,
                chapterIndex: chapterIdx,
                chapterTitle: chapterName,
                text: markText,
                colorHex: colorHex,
                createdAt: createdDate,
                note: noteContent,
                updatedAt: createdDate,
                source: "wechat_read",
                wechatBookId: wechatBookId,
                wechatBookmarkId: bm.bookmarkId,
                wechatAuthor: bookAuthor,
                isNoteLocallyEdited: false,
                isColorLocallyEdited: false
            )
            results.append(highlight)
        }

        // 2. Process Unmatched Reviews / Thoughts (e.g. standalone chapter review or book review)
        for rev in reviews where !matchedReviewIds.contains(rev.reviewId) {
            let content = rev.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }

            let quoteText = rev.abstract?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "【微信读书思考随笔】"
            let chapterName = rev.chapterName ?? "全书读后随想"
            let chapterIdx = rev.chapterIdx ?? 0
            let createdDate = Date(timeIntervalSince1970: rev.createTime)

            let highlight = Highlight(
                id: deterministicUUID(for: "wechat_rev_\(wechatBookId)_\(rev.reviewId)"),
                bookId: targetBookId,
                bookTitle: bookTitle,
                chapterIndex: chapterIdx,
                chapterTitle: chapterName,
                text: quoteText,
                colorHex: "#D8B4FE", // Soft violet for personal thoughts
                createdAt: createdDate,
                note: content,
                updatedAt: createdDate,
                source: "wechat_read",
                wechatBookId: wechatBookId,
                wechatBookmarkId: "rev_\(rev.reviewId)",
                wechatAuthor: bookAuthor,
                isNoteLocallyEdited: false,
                isColorLocallyEdited: false
            )
            results.append(highlight)
        }

        return results
    }

    // MARK: - Synchronize a Single Book
    func syncSingleBook(
        notebook: WeChatNotebookItem,
        localBooks: [EPUBBook]
    ) async throws -> [Highlight] {
        // Find matching book in DReader library if available
        let matchingLocal = localBooks.first { b in
            b.title == notebook.book.title ||
            notebook.book.title.localizedCaseInsensitiveContains(b.title) ||
            b.title.localizedCaseInsensitiveContains(notebook.book.title)
        }

        let (bookmarks, chapters) = try await fetchHighlights(for: notebook.bookId)
        let reviews = try await fetchReviews(for: notebook.bookId)

        let newHighlights = convertToDReaderHighlights(
            notebook: notebook,
            bookmarks: bookmarks,
            chapters: chapters,
            reviews: reviews,
            matchingLocalBook: matchingLocal
        )

        return newHighlights
    }

    /// 只用远端身份合并；相同引文可能来自不同随笔、章节或书籍。
    static func isSameRemoteHighlight(_ local: Highlight, _ remote: Highlight) -> Bool {
        if local.id == remote.id { return true }
        guard let localBook = local.wechatBookId, let remoteBook = remote.wechatBookId,
              let localMark = local.wechatBookmarkId, let remoteMark = remote.wechatBookmarkId else { return false }
        return localBook == remoteBook && localMark == remoteMark
    }

    static func mergeHighlights(_ incoming: [Highlight], into current: [Highlight],
                                baseline: [Highlight]? = nil, deleted: [Highlight] = []) -> [Highlight] {
        var result = current
        for remote in incoming {
            guard !deleted.contains(where: { isSameRemoteHighlight($0, remote) }) else { continue }
            let original = baseline?.first { isSameRemoteHighlight($0, remote) }
            if let index = result.firstIndex(where: { isSameRemoteHighlight($0, remote) }) {
                let local = result[index]
                if let original, local != original { continue }
                var merged = Highlight(id: local.id, bookId: remote.bookId, bookTitle: remote.bookTitle,
                    chapterIndex: remote.chapterIndex, chapterTitle: remote.chapterTitle,
                    text: remote.text, colorHex: remote.colorHex, createdAt: local.createdAt,
                    note: remote.note, updatedAt: remote.updatedAt, source: remote.source,
                    wechatBookId: remote.wechatBookId, wechatBookmarkId: remote.wechatBookmarkId,
                    wechatAuthor: remote.wechatAuthor)
                // 旧记录没有逐字段标记时保守保留；新编辑只保护实际修改的字段。
                let legacyEdited = (local.updatedAt ?? local.createdAt) > local.createdAt
                let preserveNote = local.isNoteLocallyEdited ?? legacyEdited
                let preserveColor = local.isColorLocallyEdited ?? legacyEdited
                merged.isNoteLocallyEdited = preserveNote
                merged.isColorLocallyEdited = preserveColor
                if preserveNote || merged.note?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                    merged.note = local.note
                }
                if preserveColor { merged.colorHex = local.colorHex }
                if preserveNote || preserveColor { merged.updatedAt = local.updatedAt }
                result[index] = merged
            } else if original == nil {
                result.insert(remote, at: 0)
            }
        }
        return result
    }

    // MARK: - Full Batch Sync
    func syncAllNotebooks(
        localBooks: [EPUBBook],
        onProgress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> (importedCount: Int, updatedHighlights: [Highlight]) {
        isSyncing = true
        syncProgress = 0.0
        syncStatusMessage = "正在连接微信读书云端笔记本..."
        onProgress?(0.05, "正在拉取笔记本列表...")

        defer {
            isSyncing = false
            syncProgress = 1.0
            syncStatusMessage = "同步完成"
        }

        let books = try await fetchAllNotebooks()
        guard !books.isEmpty else {
            return (0, [])
        }

        var runningHighlights: [Highlight] = []
        var newlyImportedCount = 0

        for (index, nb) in books.enumerated() {
            let progress = Double(index) / Double(books.count)
            let status = "正在同步《\(nb.book.title)》的划线与想法 (\(index + 1)/\(books.count))..."
            self.syncProgress = progress
            self.syncStatusMessage = status
            onProgress?(progress, status)

            do {
                let beforeCount = runningHighlights.count
                let incoming = try await syncSingleBook(notebook: nb, localBooks: localBooks)
                try Task.checkCancellation()
                runningHighlights = Self.mergeHighlights(incoming, into: runningHighlights)
                let added = runningHighlights.count - beforeCount
                if added > 0 {
                    newlyImportedCount += added
                }
            } catch {
                // Log and continue to next book
                print("[WeChatReadingService] Failed to sync book \(nb.book.title): \(error.localizedDescription)")
            }

            // Polite breathing room between batch gateway calls
            try? await Task.sleep(nanoseconds: 120_000_000)
        }

        let now = Date()
        self.lastSyncDate = now
        UserDefaults.standard.set(now, forKey: lastSyncTimeDefaultsKey)

        return (newlyImportedCount, runningHighlights)
    }

    // MARK: - Color Mapping Helper
    private func mapWeChatColor(_ style: Int?) -> String {
        switch style {
        case 1:
            return "#FFE066" // Gold Yellow
        case 2:
            return "#A5D8FF" // Sky Blue
        case 3:
            return "#FFC9C9" // Blossom Pink
        case 4:
            return "#D8B4FE" // Lavender Purple
        case 5:
            return "#86EFAC" // Mint Green
        default:
            return "#FFE066"
        }
    }

    // Helper for deterministic UUID generation
    private func deterministicUUID(for string: String) -> UUID {
        var hash = UInt64(5381)
        for byte in string.utf8 {
            hash = 127 * (hash & 0x00FFFFFFFFFFFFFF) + UInt64(byte)
        }
        let part1 = UInt32((hash >> 32) & 0xFFFFFFFF)
        let part2 = UInt16((hash >> 16) & 0xFFFF)
        let part3 = UInt16(hash & 0x0FFF) | 0x4000
        let part4 = UInt16(0x8000) | UInt16((hash >> 8) & 0x3FFF)
        let part5 = hash & 0xFFFFFFFFFFFF

        let uuidStr = String(
            format: "%08X-%04X-%04X-%04X-%012llX",
            part1, part2, part3, part4, part5
        )
        return UUID(uuidString: uuidStr) ?? UUID()
    }
}

// MARK: - WeChat Reading API Data Models

struct WeChatBookMeta: Codable, Sendable {
    let title: String
    let author: String
    let cover: String?
    let version: Int?
    let format: String?
}

struct WeChatNotebookItem: Identifiable, Codable, Sendable {
    var id: String { bookId }
    let bookId: String
    let book: WeChatBookMeta
    let reviewCount: Int
    let noteCount: Int
    let bookmarkCount: Int
    let readingProgress: Double?
    let markedStatus: Int?
    let sort: Int?

    var totalNotes: Int {
        reviewCount + noteCount + bookmarkCount
    }
}

struct WeChatNotebooksResponse: Codable, Sendable {
    let totalBookCount: Int?
    let totalNoteCount: Int?
    let hasMore: Int?
    let books: [WeChatNotebookItem]?
    let errcode: Int?
    let errmsg: String?
}

struct WeChatBookmarkItem: Codable, Sendable {
    let bookmarkId: String
    let bookId: String
    let chapterUid: Int?
    let markText: String
    let createTime: TimeInterval
    let type: Int?
    let range: String?
    let colorStyle: Int?
}

struct WeChatChapterInfo: Codable, Sendable {
    let chapterUid: Int
    let chapterIdx: Int
    let title: String
}

struct WeChatBookmarkListResponse: Codable, Sendable {
    let updated: [WeChatBookmarkItem]?
    let chapters: [WeChatChapterInfo]?
    let book: WeChatBookMeta?
    let errcode: Int?
    let errmsg: String?
}

struct WeChatReviewItem: Codable, Sendable {
    let reviewId: String
    let content: String
    let abstract: String?
    let range: String?
    let chapterUid: Int?
    let chapterIdx: Int?
    let chapterName: String?
    let createTime: TimeInterval
    let star: Int?
    let isFinish: Int?
}

struct WeChatReviewContainer: Codable, Sendable {
    let review: WeChatReviewItem
}

struct WeChatReviewListResponse: Codable, Sendable {
    let totalCount: Int?
    let hasMore: Int?
    let synckey: Int?
    let reviews: [WeChatReviewContainer]?
    let errcode: Int?
    let errmsg: String?
}

// MARK: - Errors
enum WeChatAPIError: LocalizedError {
    case missingApiKey
    case invalidResponse
    case unauthorized
    case serverError(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .missingApiKey:
            return "未配置微信读书 API Key。请在设置中填入你的 WEREAD_API_KEY。"
        case .invalidResponse:
            return "微信读书网关响应异常，请检查网络连接。"
        case .unauthorized:
            return "API Key 无效或已过期，请在 https://weread.qq.com/r/weread-skills 重新获取并配置。"
        case .serverError(let code, let msg):
            return "微信读书接口错误 (\(code)): \(msg)"
        }
    }
}
