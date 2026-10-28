import Foundation
import SQLite3

/// Local SQLite persistence layer for user knowledge assets (highlights, bookmarks).
/// Replaces UserDefaults storage with a real database (WAL mode) plus JSON backup support.
final class LibraryDatabase: @unchecked Sendable {
    static let shared = LibraryDatabase()

    private var db: OpaquePointer?
    private let dbQueue = DispatchQueue(label: "com.dreader.librarydb")
    private let dbURL: URL
    private let preferences: UserDefaults
    private let schedulesBackups: Bool

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private convenience init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.init(databaseURL: appSupport.appendingPathComponent("DReader/library.sqlite"),
                  preferences: .standard, schedulesBackups: true)
    }

    init(databaseURL: URL, preferences: UserDefaults, schedulesBackups: Bool = false) {
        dbURL = databaseURL
        self.preferences = preferences
        self.schedulesBackups = schedulesBackups
        try? FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        dbQueue.sync {
            openDatabase()
            createSchema()
            migrateLegacyUserDefaultsIfNeeded()
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    private func scheduleBackup() {
        if schedulesBackups { ICloudBackupService.shared.scheduleBackup() }
    }

    // MARK: - Setup

    private func openDatabase() {
        if sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            NSLog("DReader LibraryDB: failed to open \(dbURL.path)")
            db = nil
            return
        }
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
    }

    private func createSchema() {
        guard let db else { return }
        let sql = """
        CREATE TABLE IF NOT EXISTS highlights (
            id TEXT PRIMARY KEY,
            book_id TEXT NOT NULL,
            book_title TEXT NOT NULL DEFAULT '',
            chapter_index INTEGER NOT NULL DEFAULT 0,
            chapter_title TEXT NOT NULL DEFAULT '',
            text TEXT NOT NULL DEFAULT '',
            color_hex TEXT NOT NULL DEFAULT '#FFE066',
            created_at REAL NOT NULL DEFAULT 0,
            note TEXT,
            updated_at REAL,
            source TEXT,
            wechat_book_id TEXT,
            wechat_bookmark_id TEXT,
            wechat_author TEXT,
            note_locally_edited INTEGER,
            color_locally_edited INTEGER
        );
        CREATE TABLE IF NOT EXISTS bookmarks (
            id TEXT PRIMARY KEY,
            book_id TEXT NOT NULL,
            book_title TEXT NOT NULL DEFAULT '',
            chapter_index INTEGER NOT NULL DEFAULT 0,
            chapter_title TEXT NOT NULL DEFAULT '',
            scroll_progress REAL NOT NULL DEFAULT 0,
            created_at REAL NOT NULL DEFAULT 0,
            note TEXT
        );
        CREATE TABLE IF NOT EXISTS review_schedule (
            highlight_id TEXT PRIMARY KEY,
            mastery_level INTEGER NOT NULL DEFAULT 0,
            interval_days REAL NOT NULL DEFAULT 0,
            due_at REAL NOT NULL DEFAULT 0,
            review_count INTEGER NOT NULL DEFAULT 0,
            last_reviewed_at REAL,
            ease_factor REAL NOT NULL DEFAULT 2.5
        );
        CREATE INDEX IF NOT EXISTS idx_highlights_book ON highlights(book_id);
        CREATE INDEX IF NOT EXISTS idx_bookmarks_book ON bookmarks(book_id);
        CREATE INDEX IF NOT EXISTS idx_review_due ON review_schedule(due_at);
        """
        sqlite3_exec(db, sql, nil, nil, nil)
        // SM-2 ease 因子列（对已存在的旧表幂等——列已有时 ALTER 报错被忽略）
        sqlite3_exec(db, "ALTER TABLE review_schedule ADD COLUMN ease_factor REAL NOT NULL DEFAULT 2.5;", nil, nil, nil)
        sqlite3_exec(db, "ALTER TABLE highlights ADD COLUMN note_locally_edited INTEGER;", nil, nil, nil)
        sqlite3_exec(db, "ALTER TABLE highlights ADD COLUMN color_locally_edited INTEGER;", nil, nil, nil)
    }

    // MARK: - Mastery Review Scheduling (Readwise-style spaced resurfacing)

    /// A highlight joined with its review state.
    struct DueReviewCard: Sendable {
        let highlight: Highlight
        let masteryLevel: Int
        let reviewCount: Int
        let isOverdue: Bool
    }

    /// Highlights due for review, oldest-due first. New (never-reviewed) highlights
    /// surface interleaved at the end. `limit` caps the daily dose (10 by default).
    func dueReviewCards(limit: Int = 10, asOf date: Date = Date()) -> [DueReviewCard] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        let sql = """
        SELECT h.id, h.book_id, h.book_title, h.chapter_index, h.chapter_title, h.text, h.color_hex,
               h.created_at, h.note, h.updated_at, h.source, h.wechat_book_id, h.wechat_bookmark_id, h.wechat_author,
               COALESCE(r.mastery_level, 0), COALESCE(r.review_count, 0),
               CASE WHEN r.due_at IS NOT NULL AND r.due_at < ? THEN 1 ELSE 0 END,
               h.note_locally_edited, h.color_locally_edited
        FROM highlights h
        LEFT JOIN review_schedule r ON r.highlight_id = h.id
        WHERE r.highlight_id IS NULL                    -- brand-new, never scheduled
           OR r.due_at <= ?                             -- due or overdue
        ORDER BY COALESCE(r.due_at, h.created_at) ASC
        LIMIT ?
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        let now = date.timeIntervalSince1970
        sqlite3_bind_double(stmt, 1, now)
        sqlite3_bind_double(stmt, 2, now)
        sqlite3_bind_int64(stmt, 3, Int64(limit))

        var results: [DueReviewCard] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idStr = text(stmt, 0), let id = UUID(uuidString: idStr) else { continue }
            let bookIdStr = text(stmt, 1) ?? ""
            let h = Highlight(
                id: id,
                bookId: UUID(uuidString: bookIdStr) ?? UUID(),
                bookTitle: text(stmt, 2) ?? "",
                chapterIndex: Int(sqlite3_column_int64(stmt, 3)),
                chapterTitle: text(stmt, 4) ?? "",
                text: text(stmt, 5) ?? "",
                colorHex: text(stmt, 6) ?? "#FFE066",
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7)),
                note: text(stmt, 8),
                updatedAt: sqlite3_column_type(stmt, 9) != SQLITE_NULL
                    ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9)) : nil,
                source: text(stmt, 10),
                wechatBookId: text(stmt, 11),
                wechatBookmarkId: text(stmt, 12),
                wechatAuthor: text(stmt, 13),
                isNoteLocallyEdited: sqlite3_column_type(stmt, 17) == SQLITE_NULL ? nil : sqlite3_column_int(stmt, 17) != 0,
                isColorLocallyEdited: sqlite3_column_type(stmt, 18) == SQLITE_NULL ? nil : sqlite3_column_int(stmt, 18) != 0
            )
            results.append(DueReviewCard(
                highlight: h,
                masteryLevel: Int(sqlite3_column_int64(stmt, 14)),
                reviewCount: Int(sqlite3_column_int64(stmt, 15)),
                isOverdue: sqlite3_column_int64(stmt, 16) == 1
            ))
        }
        return results
    }

    /// Total cards due right now (for the badge on the review entry).
    func dueReviewCount(asOf date: Date = Date()) -> Int {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        let sql = """
        SELECT COUNT(*) FROM (
            SELECT h.id FROM highlights h
            LEFT JOIN review_schedule r ON r.highlight_id = h.id
            WHERE r.highlight_id IS NULL OR r.due_at <= ?
            LIMIT 999
        )
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970)
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    func recordReview(highlightId: UUID, score: Int, asOf date: Date = Date()) {
        guard let db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT interval_days, review_count, ease_factor FROM review_schedule WHERE highlight_id = ?", -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, highlightId.uuidString, -1, Self.transient)
        var currentInterval: Double = 0
        var currentCount = 0
        var ease = 2.5
        if sqlite3_step(stmt) == SQLITE_ROW {
            currentInterval = sqlite3_column_double(stmt, 0)
            currentCount = Int(sqlite3_column_int64(stmt, 1))
            ease = sqlite3_column_double(stmt, 2)
        }
        sqlite3_finalize(stmt)

        // SM-2 简化版：ease 因子随评分浮动，间隔 = 上一间隔 × ease
        // 完全记得(5) ease +0.1，模糊(3) 轻微收缩，忘记(1) 重挫并腰斩间隔
        ease = Self.nextEase(ease: ease, score: score)

        var newInterval: Double
        if score < 3 {
            // 遗忘：间隔腰斩（而非清零），保底 1 天——卡片不会被打回起点
            newInterval = max(1, currentInterval * 0.5)
        } else if currentInterval < 1 {
            // 首次成功复习：从 1 天起步（车道制旧数据 interval 0/7/14/28 均大于等于此档）
            newInterval = 1
        } else {
            newInterval = min(currentInterval * ease, 365)
        }

        let dueAt = date.timeIntervalSince1970 + newInterval * 86400
        let newLevel = Self.level(forInterval: newInterval)

        guard sqlite3_prepare_v2(db, """
        INSERT OR REPLACE INTO review_schedule
        (highlight_id, mastery_level, interval_days, due_at, review_count, last_reviewed_at, ease_factor)
        VALUES (?,?,?,?,?,?,?)
        """, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, highlightId.uuidString, -1, Self.transient)
        sqlite3_bind_int64(stmt, 2, Int64(newLevel))
        sqlite3_bind_double(stmt, 3, newInterval)
        sqlite3_bind_double(stmt, 4, dueAt)
        sqlite3_bind_int64(stmt, 5, Int64(currentCount + 1))
        sqlite3_bind_double(stmt, 6, date.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 7, ease)
        _ = sqlite3_step(stmt)
    }

    /// 经典 SM-2 ease 调整：EF' = EF + (0.1 − (5−q)(0.08 + (5−q)×0.02))
    /// q=5 → +0.1，q=4 → 0，q=3 → −0.14，q=1 → −0.54。夹在 [1.3, 3.0] 防失速或僵死。
    private static func nextEase(ease: Double, score: Int) -> Double {
        let d = Double(5 - min(max(score, 0), 5))
        let adjusted = ease + 0.1 - d * (0.08 + d * 0.02)
        return min(max(adjusted, 1.3), 3.0)
    }

    /// 展示等级由实际间隔推导（≥28 天视为已掌握，供徽章/统计沿用旧语义）
    private static func level(forInterval interval: Double) -> Int {
        switch interval {
        case ..<1: return 0
        case ..<7: return 1
        case ..<14: return 2
        case ..<28: return 3
        default: return 4
        }
    }

    /// Removes a highlight's schedule row when the highlight itself is deleted.
    func deleteReviewSchedule(highlightId: UUID) {
        guard let db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM review_schedule WHERE highlight_id = ?", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, highlightId.uuidString, -1, Self.transient)
        _ = sqlite3_step(stmt)
    }

    /// 某张卡当前的复习间隔（天）；从未排期返回 0。UI 用于展示记忆强度。
    func currentIntervalDays(highlightId: UUID) -> Double {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT interval_days FROM review_schedule WHERE highlight_id = ?", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, highlightId.uuidString, -1, Self.transient)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return sqlite3_column_double(stmt, 0)
    }

    /// Cards reviewed today and small stats for the session banner.
    func reviewStats(asOf date: Date = Date()) -> (reviewedToday: Int, masteredCards: Int) {
        let dayStart = Calendar.current.startOfDay(for: date).timeIntervalSince1970
        let reviewedToday = scalarCount("SELECT COUNT(*) FROM review_schedule WHERE last_reviewed_at >= \(dayStart)")
        let mastered = scalarCount("SELECT COUNT(*) FROM review_schedule WHERE mastery_level >= 3")
        return (reviewedToday, mastered)
    }

    /// 复习排期总数（进入记忆通道的卡片数）
    func scheduledCardCount() -> Int {
        scalarCount("SELECT COUNT(*) FROM review_schedule")
    }

    private func scalarCount(_ sql: String) -> Int {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// One-time migration from the legacy UserDefaults JSON blobs.
    /// Legacy data is kept in UserDefaults untouched as a belt-and-suspenders backup.
    private func migrateLegacyUserDefaultsIfNeeded() {
        guard db != nil else { return }
        let flagKey = "dreader.librarydb.migrated.v1"
        guard !preferences.bool(forKey: flagKey) else { return }

        var migrated = false

        if let data = preferences.data(forKey: "dreader.highlights"),
           let legacy = try? JSONDecoder().decode([Highlight].self, from: data),
           !legacy.isEmpty {
            let count = countRows(table: "highlights")
            if count == 0 {
                upsertHighlightsSync(legacy)
                NSLog("DReader LibraryDB: migrated \(legacy.count) highlights from UserDefaults")
            }
            migrated = true
        }

        if let data = preferences.data(forKey: "dreader.bookmarks"),
           let legacy = try? JSONDecoder().decode([Bookmark].self, from: data),
           !legacy.isEmpty {
            let count = countRows(table: "bookmarks")
            if count == 0 {
                upsertBookmarksSync(legacy)
                NSLog("DReader LibraryDB: migrated \(legacy.count) bookmarks from UserDefaults")
            }
            migrated = true
        }

        if migrated {
            preferences.set(true, forKey: flagKey)
        }
    }

    private func countRows(table: String) -> Int {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM \(table)", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    // MARK: - Highlights

    func loadHighlights() -> [Highlight] {
        dbQueue.sync { loadHighlightsSync() }
    }

    private func loadHighlightsSync() -> [Highlight] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        let sql = """
        SELECT id, book_id, book_title, chapter_index, chapter_title, text, color_hex,
               created_at, note, updated_at, source, wechat_book_id, wechat_bookmark_id, wechat_author,
               note_locally_edited, color_locally_edited
        FROM highlights ORDER BY created_at DESC
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var results: [Highlight] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idStr = text(stmt, 0), let id = UUID(uuidString: idStr) else { continue }
            let bookIdStr = text(stmt, 1) ?? ""
            let bookId = UUID(uuidString: bookIdStr) ?? UUID()
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7))
            let updatedAt = sqlite3_column_type(stmt, 9) != SQLITE_NULL
                ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9)) : nil

            results.append(Highlight(
                id: id,
                bookId: bookId,
                bookTitle: text(stmt, 2) ?? "",
                chapterIndex: Int(sqlite3_column_int64(stmt, 3)),
                chapterTitle: text(stmt, 4) ?? "",
                text: text(stmt, 5) ?? "",
                colorHex: text(stmt, 6) ?? "#FFE066",
                createdAt: createdAt,
                note: text(stmt, 8),
                updatedAt: updatedAt,
                source: text(stmt, 10),
                wechatBookId: text(stmt, 11),
                wechatBookmarkId: text(stmt, 12),
                wechatAuthor: text(stmt, 13),
                isNoteLocallyEdited: sqlite3_column_type(stmt, 14) == SQLITE_NULL ? nil : sqlite3_column_int(stmt, 14) != 0,
                isColorLocallyEdited: sqlite3_column_type(stmt, 15) == SQLITE_NULL ? nil : sqlite3_column_int(stmt, 15) != 0
            ))
        }
        return results
    }

    func upsertHighlights(_ items: [Highlight]) {
        dbQueue.sync { upsertHighlightsSync(items) }
    }

    private func upsertHighlightsSync(_ items: [Highlight]) {
        guard let db, !items.isEmpty else { return }
        var stmt: OpaquePointer?
        let sql = """
        INSERT OR REPLACE INTO highlights
        (id, book_id, book_title, chapter_index, chapter_title, text, color_hex,
         created_at, note, updated_at, source, wechat_book_id, wechat_bookmark_id, wechat_author,
         note_locally_edited, color_locally_edited)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
        for h in items {
            sqlite3_reset(stmt)
            bindText(stmt, 1, h.id.uuidString)
            bindText(stmt, 2, h.bookId.uuidString)
            bindText(stmt, 3, h.bookTitle)
            sqlite3_bind_int64(stmt, 4, Int64(h.chapterIndex))
            bindText(stmt, 5, h.chapterTitle)
            bindText(stmt, 6, h.text)
            bindText(stmt, 7, h.colorHex)
            sqlite3_bind_double(stmt, 8, h.createdAt.timeIntervalSince1970)
            bindOptionalText(stmt, 9, h.note)
            if let updated = h.updatedAt {
                sqlite3_bind_double(stmt, 10, updated.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(stmt, 10)
            }
            bindOptionalText(stmt, 11, h.source)
            bindOptionalText(stmt, 12, h.wechatBookId)
            bindOptionalText(stmt, 13, h.wechatBookmarkId)
            bindOptionalText(stmt, 14, h.wechatAuthor)
            if let edited = h.isNoteLocallyEdited {
                sqlite3_bind_int(stmt, 15, edited ? 1 : 0)
            } else {
                sqlite3_bind_null(stmt, 15)
            }
            if let edited = h.isColorLocallyEdited {
                sqlite3_bind_int(stmt, 16, edited ? 1 : 0)
            } else {
                sqlite3_bind_null(stmt, 16)
            }
            _ = sqlite3_step(stmt)
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        scheduleBackup()
    }

    func deleteHighlight(id: UUID) {
        dbQueue.sync {
            guard let db else { return }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM highlights WHERE id = ?", -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, id.uuidString)
            _ = sqlite3_step(stmt)
            scheduleBackup()
        }
    }

    // MARK: - Vocabulary Builder (Kindle 生词本闭环)

    /// Kindle Vocabulary Builder 范式：查过的词收进生词本（source = "vocabulary" 的划线条目），
    /// 首次复习排程复用 review_schedule —— 查过的词自然进入 7/14/28 天精通队列。
    /// 按（词 + 书名）去重；同一本书不重复收录，跨书可分别积累语境。
    @discardableResult
    func upsertVocabularyWord(_ word: String, bookId: UUID, bookTitle: String, chapterTitle: String) -> Highlight? {
        let cleaned = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count <= 24 else { return nil }

        return dbQueue.sync {
            guard let db else { return nil }
            // 去重：同词 + 同书已收录
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, """
            SELECT id FROM highlights
            WHERE source = 'vocabulary' AND text = ? AND book_title = ? LIMIT 1
            """, -1, &stmt, nil) == SQLITE_OK else { return nil }
            sqlite3_bind_text(stmt, 1, cleaned, -1, Self.transient)
            sqlite3_bind_text(stmt, 2, bookTitle, -1, Self.transient)
            let exists = sqlite3_step(stmt) == SQLITE_ROW
            sqlite3_finalize(stmt)
            guard !exists else { return nil }

            let entry = Highlight(
                bookId: bookId,
                bookTitle: bookTitle,
                chapterIndex: 0,
                chapterTitle: chapterTitle,
                text: cleaned,
                colorHex: "#A5D8FF",
                createdAt: Date(),
                source: "vocabulary"
            )
            upsertHighlightsSync([entry])
            return entry
        }
    }

    /// 生词总数（书架生词本入口角标用）
    func vocabularyCount() -> Int {
        dbQueue.sync {
            guard let db else { return 0 }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM highlights WHERE source = 'vocabulary'", -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
        }
    }

    /// 某本书最后一次「留下印记」的记录（划线/书签/生词的时间与所在章），前情回顾的判定源。
    /// 单一 MAX 聚合下 SQLite 的 bare columns 取自极值所在行，章节信息与时间同源。
    func latestActivity(bookTitle: String) -> (chapterIndex: Int, chapterTitle: String, date: Date)? {
        dbQueue.sync {
            guard let db else { return nil }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT chapter_index, chapter_title, MAX(created_at) FROM highlights WHERE book_title = ?", -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, bookTitle, -1, Self.transient)
            guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 2) != SQLITE_NULL else { return nil }
            let idx = Int(sqlite3_column_int64(stmt, 0))
            let title = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            return (idx, title, Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)))
        }
    }

    // MARK: - Bookmarks

    func loadBookmarks() -> [Bookmark] {
        dbQueue.sync { loadBookmarksSync() }
    }

    private func loadBookmarksSync() -> [Bookmark] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        let sql = """
        SELECT id, book_id, book_title, chapter_index, chapter_title, scroll_progress, created_at, note
        FROM bookmarks ORDER BY created_at DESC
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var results: [Bookmark] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idStr = text(stmt, 0), let id = UUID(uuidString: idStr) else { continue }
            let bookIdStr = text(stmt, 1) ?? ""
            let bookId = UUID(uuidString: bookIdStr) ?? UUID()
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
            let note = text(stmt, 7)
            results.append(Bookmark(
                id: id,
                bookId: bookId,
                bookTitle: text(stmt, 2) ?? "",
                chapterIndex: Int(sqlite3_column_int64(stmt, 3)),
                chapterTitle: text(stmt, 4) ?? "",
                scrollProgress: sqlite3_column_double(stmt, 5),
                createdAt: createdAt,
                note: note
            ))
        }
        return results
    }

    func upsertBookmarks(_ items: [Bookmark]) {
        dbQueue.sync { upsertBookmarksSync(items) }
    }

    private func upsertBookmarksSync(_ items: [Bookmark]) {
        guard let db, !items.isEmpty else { return }
        var stmt: OpaquePointer?
        let sql = """
        INSERT OR REPLACE INTO bookmarks
        (id, book_id, book_title, chapter_index, chapter_title, scroll_progress, created_at, note)
        VALUES (?,?,?,?,?,?,?,?)
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
        for b in items {
            sqlite3_reset(stmt)
            bindText(stmt, 1, b.id.uuidString)
            bindText(stmt, 2, b.bookId.uuidString)
            bindText(stmt, 3, b.bookTitle)
            sqlite3_bind_int64(stmt, 4, Int64(b.chapterIndex))
            bindText(stmt, 5, b.chapterTitle)
            sqlite3_bind_double(stmt, 6, b.scrollProgress)
            sqlite3_bind_double(stmt, 7, b.createdAt.timeIntervalSince1970)
            bindOptionalText(stmt, 8, b.note)
            _ = sqlite3_step(stmt)
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        scheduleBackup()
    }

    func deleteBookmark(id: UUID) {
        dbQueue.sync {
            guard let db else { return }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM bookmarks WHERE id = ?", -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, id.uuidString)
            _ = sqlite3_step(stmt)
            scheduleBackup()
        }
    }

    // MARK: - JSON Backup (Export / Import)

    struct BackupPayload: Codable {
        var version: Int = 1
        var exportedAt: Date = Date()
        var highlights: [Highlight] = []
        var bookmarks: [Bookmark] = []
    }

    func exportBackup() throws -> Data {
        let payload = dbQueue.sync { () -> BackupPayload in
            BackupPayload(highlights: loadHighlightsSync(), bookmarks: loadBookmarksSync())
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }

    /// Imports a backup payload, merging by id (existing rows are overwritten).
    /// Returns the number of imported highlights + bookmarks.
    func importBackup(_ data: Data) throws -> Int {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(BackupPayload.self, from: data)
        dbQueue.sync {
            upsertHighlightsSync(payload.highlights)
            upsertBookmarksSync(payload.bookmarks)
        }
        return payload.highlights.count + payload.bookmarks.count
    }

    // MARK: - SQLite Helpers

    private func text(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        guard let cString = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cString)
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, Self.transient)
    }

    private func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value, !value.isEmpty {
            sqlite3_bind_text(stmt, index, value, -1, Self.transient)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }
}
