import Foundation
import SQLite3

/// Local SQLite persistence layer for user knowledge assets (highlights, bookmarks).
/// Replaces UserDefaults storage with a real database (WAL mode) plus JSON backup support.
final class LibraryDatabase: @unchecked Sendable {
    static let shared = LibraryDatabase()

    private var db: OpaquePointer?
    private let dbQueue = DispatchQueue(label: "com.dreader.librarydb")
    private let dbURL: URL

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("DReader", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbURL = dir.appendingPathComponent("library.sqlite")

        dbQueue.sync {
            openDatabase()
            createSchema()
            migrateLegacyUserDefaultsIfNeeded()
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
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
            wechat_author TEXT
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
        CREATE INDEX IF NOT EXISTS idx_highlights_book ON highlights(book_id);
        CREATE INDEX IF NOT EXISTS idx_bookmarks_book ON bookmarks(book_id);
        """
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    /// One-time migration from the legacy UserDefaults JSON blobs.
    /// Legacy data is kept in UserDefaults untouched as a belt-and-suspenders backup.
    private func migrateLegacyUserDefaultsIfNeeded() {
        guard db != nil else { return }
        let flagKey = "dreader.librarydb.migrated.v1"
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }

        var migrated = false

        if let data = UserDefaults.standard.data(forKey: "dreader.highlights"),
           let legacy = try? JSONDecoder().decode([Highlight].self, from: data),
           !legacy.isEmpty {
            let count = countRows(table: "highlights")
            if count == 0 {
                upsertHighlightsSync(legacy)
                NSLog("DReader LibraryDB: migrated \(legacy.count) highlights from UserDefaults")
            }
            migrated = true
        }

        if let data = UserDefaults.standard.data(forKey: "dreader.bookmarks"),
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
            UserDefaults.standard.set(true, forKey: flagKey)
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
               created_at, note, updated_at, source, wechat_book_id, wechat_bookmark_id, wechat_author
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
                wechatAuthor: text(stmt, 13)
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
         created_at, note, updated_at, source, wechat_book_id, wechat_bookmark_id, wechat_author)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
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
            _ = sqlite3_step(stmt)
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    func deleteHighlight(id: UUID) {
        dbQueue.sync {
            guard let db else { return }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM highlights WHERE id = ?", -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, id.uuidString)
            _ = sqlite3_step(stmt)
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
    }

    func deleteBookmark(id: UUID) {
        dbQueue.sync {
            guard let db else { return }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM bookmarks WHERE id = ?", -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, id.uuidString)
            _ = sqlite3_step(stmt)
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
