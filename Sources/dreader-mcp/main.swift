// dreader-mcp — 让任意 MCP 客户端（Claude Desktop、Cursor 等）直接读本地 DReader 书库。
//
// 传输：stdio，newline-delimited JSON-RPC 2.0（MCP 2024-11-05 协议）。
// 数据源全部只读：
//   * ~/Library/Application Support/DReader/library.sqlite        （划线 / 思考 / 书签 / 复习排期）
//   * ~/Library/Application Support/DReader[/DownloadedBooks]/*.epub（书架文件，解析 OPF 取真实书名）
//   * ~/Library/Caches/com.dreader.cache/<bookId>/                  （GUI 已解压的渲染缓存，优先从这里读章节）

import Foundation
import SQLite3
import CryptoKit

let mcpProtocolVersion = "2024-11-05"

// MARK: - 位置

enum LibraryLocations {
    private static func overrideRoot(_ name: String) -> URL? {
        guard let path = ProcessInfo.processInfo.environment[name], path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    static var appSupport: URL {
        overrideRoot("DREADER_APP_SUPPORT_ROOT") ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("DReader", isDirectory: true)
    }
    static var sqlitePath: String { appSupport.appendingPathComponent("library.sqlite").path }
    static var shelfDirs: [URL] {
        let roots: [URL]
        if let root = overrideRoot("DREADER_EPUB_ROOT") { roots = [root] }
        else { roots = [appSupport, appSupport.appendingPathComponent("DownloadedBooks", isDirectory: true)] }
        // GUI preserves colliding basenames in DownloadedBooks/Variants/<digest>/.
        let variants = roots.flatMap { root -> [URL] in
            let directory = root.appendingPathComponent("Variants", isDirectory: true)
            return (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]))?
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true } ?? []
        }
        return roots + variants
    }
    static var cachesRoot: URL {
        overrideRoot("DREADER_CACHE_ROOT") ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.dreader.cache", isDirectory: true)
    }
    static var identityRoot: URL {
        overrideRoot("DREADER_IDENTITY_ROOT") ?? appSupport.appendingPathComponent("EPUBIdentities", isDirectory: true)
    }

    // Shared on-disk protocol with EPUBIdentity in the GUI target. Both targets
    // intentionally remain dependency-free; keep schema/version and hashes equal.
    private struct IdentityRecord: Decodable {
        let version: Int
        let fileName: String
        let legacyArchiveFingerprints: [String]
        let legacyPayloadFingerprint: String
    }
    private struct CacheMarker: Decodable {
        let version: Int
        let fileName: String
        let bookID: UUID
        let archiveFingerprint: String
        let sourceFingerprint: String
        let payloadFingerprint: String
    }
    static func bookId(forFileName fileName: String) -> UUID {
        let hash = fileName.utf8.reduce(into: UInt64(14695981039346656037)) { $0 = ($0 ^ UInt64($1)) &* 1099511628211 }
        return UUID(uuid: (
            UInt8(truncatingIfNeeded: hash), UInt8(truncatingIfNeeded: hash >> 8),
            UInt8(truncatingIfNeeded: hash >> 16), UInt8(truncatingIfNeeded: hash >> 24),
            UInt8(truncatingIfNeeded: hash >> 32), UInt8(truncatingIfNeeded: hash >> 40),
            UInt8(truncatingIfNeeded: hash >> 48), UInt8(truncatingIfNeeded: hash >> 56),
            0x44, 0x52, 0x65, 0x61, 0x64, 0x65, 0x72, 0x31
        ))
    }
    static func archiveFingerprint(for fileURL: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        var hash = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
        } catch { return nil }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func contentBookID(fileName: String, fingerprint: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data("DReader2\0\(fileName)\0\(fingerprint)".utf8)))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
    static func cacheDir(forFileURL fileURL: URL, archiveFingerprint knownFingerprint: String? = nil) -> URL? {
        guard let fingerprint = knownFingerprint ?? archiveFingerprint(for: fileURL) else { return nil }
        let fileName = fileURL.lastPathComponent
        let legacyID = bookId(forFileName: fileName)
        let recordURL = identityRoot.appendingPathComponent(legacyID.uuidString + ".json")
        guard let data = try? Data(contentsOf: recordURL),
              let record = try? JSONDecoder().decode(IdentityRecord.self, from: data),
              record.version == 1, record.fileName == fileName else { return nil }
        let bookID = record.legacyArchiveFingerprints.contains(fingerprint) ? legacyID : contentBookID(fileName: fileName, fingerprint: fingerprint)
        let directory = cachesRoot.appendingPathComponent("\(bookID.uuidString)-\(fingerprint)", isDirectory: true)
        guard let markerData = try? Data(contentsOf: directory.appendingPathComponent(".dreader-cache.json")),
              let marker = try? JSONDecoder().decode(CacheMarker.self, from: markerData),
              marker.version == 1, marker.fileName == fileName, marker.bookID == bookID,
              marker.archiveFingerprint == fingerprint else { return nil }
        return directory
    }
}

// MARK: - 轻量正则 / 解析助手

private func matches(_ pattern: String, in text: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let range = Range(NSRange(location: 0, length: (text as NSString).length), in: text) else { return [] }
    var out: [String] = []
    regex.enumerateMatches(in: text, range: NSRange(range, in: text)) { match, _, _ in
        guard let match, let r = Range(match.range, in: text) else { return }
        out.append(String(text[r]))
    }
    return out
}

private func firstMatch(_ pattern: String, captureGroup: Int, in text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let first = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
          captureGroup < first.numberOfRanges else { return nil }
    let nsRange = first.range(at: captureGroup)
    guard nsRange.location != NSNotFound, let matched = Range(nsRange, in: text) else { return nil }
    return String(text[matched])
}

private func attr(named name: String, in markup: String) -> String? {
    let result = firstMatch("(?i)\(name)\\s*=\\s*\"([^\"]*)\"", captureGroup: 1, in: markup)
        ?? firstMatch("(?i)\(name)\\s*=\\s*'([^']*)'", captureGroup: 1, in: markup)
    return result?.removingPercentEncoding ?? result
}

private func content(ofTag tag: String, in markup: String) -> String? {
    firstMatch("(?is)<\(tag)\\b[^>]*>([\\s\\S]*?)</\(tag)>", captureGroup: 1, in: markup)
}

private func resolvePath(base opfPath: String, relative href: String) -> String {
    var comps = opfPath.split(separator: "/").dropLast().map(String.init)
    for part in href.split(separator: "/") {
        switch part {
        case ".": continue
        case "..": if !comps.isEmpty { comps.removeLast() }
        default: comps.append(String(part))
        }
    }
    return comps.joined(separator: "/")
}

// MARK: - EPUB 章节 / 书架

struct ShelfBook {
    let fileName: String
    let fileURL: URL
    let title: String
    let author: String
    let chapterCount: Int
    let opfPath: String
    let archiveFingerprint: String?
}

private func zipMemberString(epub: URL, member: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-p", epub.path, member]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    // Drain while unzip is running: a chapter can exceed the pipe buffer and
    // otherwise block unzip before waitUntilExit() can return.
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)
}

private func opfFor(_ epub: URL) -> (path: String, markup: String)? {
    guard let container = zipMemberString(epub: epub, member: "META-INF/container.xml"),
          let opfPath = attr(named: "full-path", in: matches("<rootfile\\b[^>]*>", in: container).first ?? "") ?? firstMatch("<rootfile\\b[^>]*full-path=[\"']([^\"']+)[\"']", captureGroup: 1, in: container),
          let markup = zipMemberString(epub: epub, member: opfPath) else { return nil }
    return (opfPath, markup)
}

private func loadShelf() -> [ShelfBook] {
    var seen = Set<String>()
    var titles = Set<String>()
    var books: [ShelfBook] = []
    let fm = FileManager.default
    var sources: [(url: URL, modified: Date)] = []
    for dir in LibraryLocations.shelfDirs {
        for epub in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where epub.pathExtension.lowercased() == "epub" {
            let modified = (try? epub.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            sources.append((epub, modified))
        }
    }
    // Match GUI restore: a newer variant wins even when the old top-level EPUB
    // was enumerated first. A path tie-break keeps equal timestamps repeatable.
    sources.sort {
        if $0.modified != $1.modified { return $0.modified > $1.modified }
        return $0.url.standardizedFileURL.path < $1.url.standardizedFileURL.path
    }
    for source in sources {
        let epub = source.url
        let name = epub.lastPathComponent
        let fingerprint = LibraryLocations.archiveFingerprint(for: epub)
        let key = name + "\0" + (fingerprint ?? epub.standardizedFileURL.path)
        guard !seen.contains(key) else { continue }
        var title = name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: ".epub", with: "")
        var author = ""
        var chapterCount = 0
        var opfPath = ""
        if let opf = opfFor(epub) {
            opfPath = opf.path
            if let t = content(ofTag: "dc:title", in: opf.markup)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { title = t }
            if let a = content(ofTag: "dc:creator", in: opf.markup)?.trimmingCharacters(in: .whitespacesAndNewlines) { author = a }
            chapterCount = max(0, opf.markup.components(separatedBy: "<itemref").count - 1)
        }
        guard !titles.contains(title) else { continue }
        seen.insert(key)
        titles.insert(title)
        books.append(ShelfBook(fileName: name, fileURL: epub, title: title, author: author, chapterCount: chapterCount, opfPath: opfPath, archiveFingerprint: fingerprint))
    }
    return books
}

private func spinePaths(of book: ShelfBook) -> [String] {
    guard !book.opfPath.isEmpty,
          let opfMarkup = zipMemberString(epub: book.fileURL, member: book.opfPath) else { return [] }
    var idToHref: [String: String] = [:]
    for item in matches("<item\\b[^>]*>", in: opfMarkup) {
        guard let id = attr(named: "id", in: item), let href = attr(named: "href", in: item) else { continue }
        idToHref[id] = href
    }
    var spine: [String] = []
    for ref in matches("<itemref\\b[^>]*>", in: opfMarkup) {
        guard let idref = attr(named: "idref", in: ref), let href = idToHref[idref] else { continue }
        spine.append(resolvePath(base: book.opfPath, relative: href))
    }
    return spine
}

private func htmlToText(_ html: String) -> String {
    var text = html
    text = text.replacingOccurrences(of: "(?s)<!DOCTYPE[^>]*>", with: "")
    text = text.replacingOccurrences(of: "(?s)<\\?.*?\\?>", with: "")
    text = text.replacingOccurrences(of: "(?s)<!--.*?-->", with: "")
    text = text.replacingOccurrences(of: "(?s)<(script|style)[^>]*>[\\s\\S]*?</\\1>", with: " ", options: .regularExpression)
    text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
    text = text.replacingOccurrences(of: "</(p|div|h[1-6]|li|tr|blockquote)>", with: "\n\n", options: [.regularExpression, .caseInsensitive])
    text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&#39;": "'"]
    for (key, char) in entities { text = text.replacingOccurrences(of: key, with: char) }
    text = text.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
    text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func chapterText(of book: ShelfBook, chapterIndex: Int) -> String? {
    let paths = spinePaths(of: book)
    guard paths.indices.contains(chapterIndex) else { return nil }
    let member = paths[chapterIndex]
    // 优先读 GUI 已解压的渲染缓存（快、与界面上看到的一致）
    if let cacheDir = LibraryLocations.cacheDir(forFileURL: book.fileURL, archiveFingerprint: book.archiveFingerprint), !book.opfPath.isEmpty {
        let fileURL = cacheDir.appendingPathComponent(member).standardizedFileURL.resolvingSymlinksInPath()
        if fileURL.path.hasPrefix(cacheDir.standardizedFileURL.resolvingSymlinksInPath().path + "/"),
           let data = try? Data(contentsOf: fileURL), let html = String(data: data, encoding: .utf8) {
            let text = htmlToText(html)
            if !text.isEmpty { return text }
        }
    }
    if let html = zipMemberString(epub: book.fileURL, member: member) {
        let text = htmlToText(html)
        return text.isEmpty ? nil : text
    }
    return nil
}

// MARK: - SQLite 只读查询

private func readRows(sql: String, binds: [String] = [], limit: Int = 200) -> [[String: Any]] {
    var db: OpaquePointer?
    var opened = sqlite3_open_v2(LibraryLocations.sqlitePath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK
    if !opened, db != nil { sqlite3_close(db); db = nil; opened = sqlite3_open_v2(LibraryLocations.sqlitePath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK }
    guard opened, let handle = db else {
        FileHandle.standardError.write(Data("dreader-mcp: cannot open \(LibraryLocations.sqlitePath)\n".utf8))
        return []
    }
    defer { sqlite3_close(handle) }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let statement = stmt else {
        FileHandle.standardError.write(Data("dreader-mcp: prepare failed: \(sql.prefix(80))\n".utf8))
        return []
    }
    defer { sqlite3_finalize(statement) }
    for (idx, value) in binds.enumerated() {
        sqlite3_bind_text(statement, Int32(idx + 1), value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
    var rows: [[String: Any]] = []
    while rows.count < limit {
        guard sqlite3_step(statement) == SQLITE_ROW else { break }
        var row: [String: Any] = [:]
        for col in 0..<sqlite3_column_count(statement) {
            let name = String(cString: sqlite3_column_name(statement, col))
            switch sqlite3_column_type(statement, col) {
            case SQLITE_INTEGER: row[name] = Int(sqlite3_column_int64(statement, col))
            case SQLITE_FLOAT: row[name] = sqlite3_column_double(statement, col)
            case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(statement, col))
            default: row[name] = NSNull()
            }
        }
        rows.append(row)
    }
    return rows
}

private func scalar(_ sql: String, binds: [String] = []) -> Int {
    readRows(sql: sql, binds: binds).first?.values.compactMap { $0 as? Int }.first ?? 0
}

/// 采用与 GUI 相同的 CoreFoundation 管线把字符串归一为简体，
/// 让「三国演义」也能命中繁体书名《三國志演義》。
private func simplified(_ s: String) -> String {
    guard !s.isEmpty else { return s }
    let mutable = NSMutableString(string: s) as CFMutableString
    CFStringTransform(mutable, nil, "Traditional-Simplified" as CFString, false)
    return mutable as String
}

private func findShelfBook(_ fuzzyTitle: String) -> ShelfBook? {
    let books = loadShelf()
    let needle = simplified(fuzzyTitle)
    let norm = books.map { simplified($0.title) }
    // 打分匹配：全等 > 前缀/包含 > 逐字符子序列（「三国演义」命中《三國志演義》）
    var best: (score: Int, book: ShelfBook)?
    for (i, book) in books.enumerated() {
        let hay = norm[i]
        guard !hay.isEmpty else { continue }
        let score: Int
        if hay == needle, !needle.isEmpty {
            score = 4
        } else if hay.hasPrefix(needle), !needle.isEmpty {
            score = 3
        } else if hay.contains(needle), !needle.isEmpty {
            score = 2
        } else if isSubsequence(needle, in: hay) {
            score = 1
        } else {
            continue
        }
        if best == nil || score > best!.score {
            best = (score, book)
        }
    }
    return best?.book
}

private func isSubsequence(_ needle: String, in hay: String) -> Bool {
    var cursor = hay.startIndex
    for ch in needle {
        guard cursor < hay.endIndex else { return false }
        while cursor < hay.endIndex, hay[cursor] != ch { cursor = hay.index(after: cursor) }
        guard cursor < hay.endIndex else { return false }
        cursor = hay.index(after: cursor)
    }
    return true
}

// MARK: - JSON-RPC 收发

private func writeLine(_ line: String) {
    FileHandle.standardOutput.write((line + "\n").data(using: .utf8)!)
}

private func sendResult(id: Any?, _ result: [String: Any]) {
    var payload: [String: Any] = ["jsonrpc": "2.0", "result": result]
    if let id { payload["id"] = id }
    if let data = try? JSONSerialization.data(withJSONObject: payload),
       let line = String(data: data, encoding: .utf8) {
        writeLine(line)
    }
}

private func sendError(id: Any?, code: Int, message: String) {
    let safeID: Any = id ?? NSNull()
    let payload: [String: Any] = ["jsonrpc": "2.0", "id": safeID, "error": ["code": code, "message": message]]
    if let data = try? JSONSerialization.data(withJSONObject: payload),
       let line = String(data: data, encoding: .utf8) {
        writeLine(line)
    }
}

// MARK: - 工具定义

let toolSchemas: [[String: Any]] = [
    [
        "name": "list_books",
        "description": "List the user's whole DReader bookshelf: titles, authors, chapter counts, highlight counts, and source filenames.",
        "inputSchema": [
            "type": "object",
            "properties": [:] as [String: Any],
            "required": [] as [String]
        ] as [String: Any]
    ],
    [
        "name": "search_highlights",
        "description": "Search the user's saved highlights and personal notes across the entire DReader library. Substring match; Chinese phrases work fine.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "query": ["type": "string", "description": "Keywords to look up inside highlights and notes"],
                "book_filter": ["type": "string", "description": "Optional: restrict to one book (fuzzy title match)"],
                "limit": ["type": "integer", "description": "Max results, default 20, cap 100"]
            ],
            "required": ["query"]
        ] as [String: Any]
    ],
    [
        "name": "get_book_notes",
        "description": "Fetch all highlights and personal thoughts the user saved in one book of the DReader app, ordered by chapter.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "book_title": ["type": "string", "description": "Exact or partial book title as on the shelf"]
            ],
            "required": ["book_title"]
        ] as [String: Any]
    ],
    [
        "name": "get_chapter_text",
        "description": "Read a book chapter in plain text from the local DReader library. chapter_index is zero-based spine order; use list_books first.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "book_title": ["type": "string", "description": "Book title as shown on the shelf (fuzzy match)"],
                "chapter_index": ["type": "integer", "description": "Zero-based chapter index"],
                "convert_to_simplified": ["type": "boolean", "description": "Optional: also convert Traditional Chinese output to Simplified"]
            ],
            "required": ["book_title", "chapter_index"]
        ] as [String: Any]
    ],
    [
        "name": "get_reading_stats",
        "description": "Summarize the DReader knowledge base: totals, spaced-repetition schedule lanes, per-book highlight leaders.",
        "inputSchema": [
            "type": "object",
            "properties": [:] as [String: Any],
            "required": [] as [String]
        ] as [String: Any]
    ],
]

// MARK: - 工具实现

private func toolResult(_ markdown: String) -> [String: Any] {
    ["content": [["type": "text", "text": markdown]], "isError": false]
}

private func dispatchTool(_ name: String, _ args: [String: Any]) -> [String: Any] {
    switch name {
    case "list_books":
        let books = loadShelf()
        if books.isEmpty { return toolResult("书架为空（未在本地找到 DReader EPUB 文件）。") }
        var md = "DReader 书架，共 \(books.count) 本\n\n| # | 书名 | 作者 | 章节 | 划线 | 文件 |\n|---|------|------|------|------|------|\n"
        for (i, book) in books.enumerated() {
            let hl = scalar("SELECT COUNT(*) AS c FROM highlights WHERE book_title = ?", binds: [book.title])
            md += "| \(i + 1) | \(book.title) | \(book.author.isEmpty ? "—" : book.author) | \(book.chapterCount) | \(hl) | `\(book.fileName)` |\n"
        }
        return toolResult(md)

    case "search_highlights":
        guard let query = args["query"] as? String, !query.isEmpty else { return toolResult("缺少 query 参数") }
        let bookFilter = args["book_filter"] as? String ?? ""
        let limit = min(max(args["limit"] as? Int ?? 20, 1), 100)
        var sql = "SELECT book_title, chapter_title, text, note, source, datetime(created_at, 'unixepoch', 'localtime') AS ts FROM highlights WHERE (text LIKE ?1 OR note LIKE ?1)"
        var binds: [String] = ["%\(query)%"]
        if !bookFilter.isEmpty {
            sql += " AND book_title LIKE ?2"
            binds.append("%\(bookFilter)%")
        }
        sql += " ORDER BY created_at DESC LIMIT \(limit) OFFSET 0"
        let rows = readRows(sql: sql, binds: binds, limit: limit)
        if rows.isEmpty { return toolResult("「\(query)」没有命中任何划线或思考。") }
        var md = "共 \(rows.count) 条命中「\(query)」\n\n"
        for (i, row) in rows.enumerated() {
            let book = row["book_title"] as? String ?? "?"
            let chapter = row["chapter_title"] as? String ?? ""
            let text = row["text"] as? String ?? ""
            let note = row["note"] as? String
            let wechat = (row["source"] as? String) == "wechat_read" ? "（微信读书）" : ""
            md += "**\(i + 1).** 《\(book)》· \(chapter)\(wechat)\n> \(text)\n"
            if let note, !note.isEmpty { md += "💭 \(note)\n" }
            md += "\n"
        }
        return toolResult(md)

    case "get_book_notes":
        guard let title = args["book_title"] as? String, !title.isEmpty else { return toolResult("缺少 book_title 参数") }
        guard let book = findShelfBook(title) else { return toolResult("书架上没有找到《\(title)》。") }
        let rows = readRows(
            sql: "SELECT chapter_index, chapter_title, text, note, datetime(created_at, 'unixepoch', 'localtime') AS ts FROM highlights WHERE book_title = ? ORDER BY chapter_index ASC, created_at ASC",
            binds: [book.title], limit: 400
        )
        if rows.isEmpty { return toolResult("《\(book.title)》还没有任何划线或思考。") }
        var md = "《\(book.title)》划线与思考，共 \(rows.count) 条\n\n"
        var lastChapter = -1
        for (i, row) in rows.enumerated() {
            let chapterIndex = row["chapter_index"] as? Int ?? 0
            if chapterIndex != lastChapter {
                lastChapter = chapterIndex
                let chapterTitle = row["chapter_title"] as? String ?? ""
                md += "### 第 \(chapterIndex + 1) 章 \(chapterTitle.isEmpty ? "" : "· " + chapterTitle)\n"
            }
            md += "**\(i + 1).** > \(row["text"] as? String ?? "")\n"
            if let note = row["note"] as? String, !note.isEmpty { md += "💭 \(note)\n" }
            md += "\n"
        }
        return toolResult(md)

    case "get_chapter_text":
        guard let title = args["book_title"] as? String else { return toolResult("缺少 book_title 参数") }
        guard let chapterIndex = args["chapter_index"] as? Int else { return toolResult("缺少 chapter_index 参数") }
        guard let book = findShelfBook(title) else { return toolResult("书架上没有找到《\(title)》。") }
        let paths = spinePaths(of: book)
        guard paths.indices.contains(chapterIndex) else {
            return toolResult("章节序号 \(chapterIndex) 越界：《\(book.title)》共 \(paths.count) 章（0 ~ \(max(paths.count - 1, 0))）。")
        }
        guard var text = chapterText(of: book, chapterIndex: chapterIndex) else {
            return toolResult("这一章的正文暂不可读（未解压且 zip 内读取失败）。")
        }
        if args["convert_to_simplified"] as? Bool == true {
            text = simplified(text)
        }
        var md = "《\(book.title)》第 \(chapterIndex + 1) / \(paths.count) 章\n\n"
        for paragraph in text.components(separatedBy: "\n\n").prefix(600) {
            let p = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            if !p.isEmpty { md += p + "\n\n" }
        }
        if md.count > 24000 { md = String(md.prefix(24000)) + "\n\n[本章较长，已截断；如需后续段落请换一个更细的索引或让我摘要]" }
        return toolResult(md)

    case "get_reading_stats":
        let total = scalar("SELECT COUNT(*) AS c FROM highlights")
        let notes = scalar("SELECT COUNT(*) AS c FROM highlights WHERE note IS NOT NULL AND note <> ''")
        let wechat = scalar("SELECT COUNT(*) AS c FROM highlights WHERE source = 'wechat_read'")
        let bookmarks = scalar("SELECT COUNT(*) AS c FROM bookmarks")
        let scheduled = scalar("SELECT COUNT(*) AS c FROM review_schedule")
        let now = Date().timeIntervalSince1970
        let due = scalar("SELECT COUNT(*) AS c FROM review_schedule WHERE due_at <= ?", binds: [String(Int(now))])
        let lanes = readRows(sql: "SELECT mastery_level AS lane, COUNT(*) AS c FROM review_schedule GROUP BY mastery_level ORDER BY lane")
        let top = readRows(sql: "SELECT book_title AS title, COUNT(*) AS c FROM highlights GROUP BY book_title ORDER BY c DESC LIMIT 10")
        var md = "DReader 知识库总览（\(Date().formatted(date: .abbreviated, time: .omitted))）\n\n"
        md += "- 划线总量：**\(total)** 条（其中带思考笔记 \(notes) 条，微信读书同步 \(wechat) 条）\n"
        md += "- 书签：\(bookmarks) 个\n"
        md += "- 复习排期：\(scheduled) 张记忆卡片，今日到期 **\(due)** 张\n\n"
        if !lanes.isEmpty {
            md += "### 记忆通道分布\n\n| 通道 | 张数 |\n|---|---|\n"
            for lane in lanes {
                let level = lane["lane"] as? Int ?? 0
                md += "| L\(level)（\(level == 0 ? "新卡" : "半衰期 \(level == 1 ? 7 : level == 2 ? 14 : 28) 天")） | \(lane["c"] as? Int ?? 0) |\n"
            }
            md += "\n"
        }
        if !top.isEmpty {
            md += "### 划线最多的书\n\n"
            for (i, row) in top.enumerated() {
                md += "\(i + 1). 《\(row["title"] as? String ?? "?")》 — \(row["c"] as? Int ?? 0) 条\n"
            }
        }
        return toolResult(md)

    default:
        return ["content": [["type": "text", "text": "未知工具：\(name)"]], "isError": true]
    }
}

@MainActor
private func handleLine(_ lineData: Data) {
    guard let line = String(data: lineData, encoding: .utf8) else { return }
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    guard let data = trimmed.data(using: .utf8),
          let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let method = msg["method"] as? String else {
        sendError(id: nil, code: -32600, message: "Invalid JSON-RPC request")
        return
    }
    if method.hasPrefix("notifications/") { return }
    let id = msg["id"]

    switch method {
    case "initialize":
        sendResult(id: id, [
            "protocolVersion": mcpProtocolVersion,
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "dreader-mcp", "version": "1.0.0"]
        ])
    case "tools/list":
        sendResult(id: id, ["tools": toolSchemas])
    case "tools/call":
        let params = msg["params"] as? [String: Any] ?? [:]
        let toolName = params["name"] as? String ?? ""
        let toolArgs = params["arguments"] as? [String: Any] ?? [:]
        sendResult(id: id, dispatchTool(toolName, toolArgs))
    case "ping":
        sendResult(id: id, [:])
    default:
        sendError(id: id, code: -32601, message: "Method not found: \(method)")
    }
}

// MARK: - 主循环（newline-delimited stdio）

FileHandle.standardError.write(Data("dreader-mcp: ready (list_books / search_highlights / get_book_notes / get_chapter_text / get_reading_stats)\n".utf8))

var lineBuffer = Data()
while true {
    let chunk = FileHandle.standardInput.availableData
    if chunk.isEmpty { break } // stdin EOF → 干净退出
    lineBuffer.append(chunk)
    while let newline = lineBuffer.firstIndex(of: 0x0A) {
        let line = lineDataSlice(lineBuffer, upTo: newline)
        lineBuffer.removeSubrange(lineBuffer.startIndex...newline)
        handleLine(line)
    }
}
// 流剩下的最后一行（无换行符结尾）也处理掉
if !lineBuffer.isEmpty {
    handleLine(lineBuffer)
}

/// subdata helper that keeps index arithmetic simple
private func lineDataSlice(_ data: Data, upTo index: Data.Index) -> Data {
    data.subdata(in: data.startIndex..<index)
}
