import Foundation
import SwiftUI

/// Represents an EPUB book loaded into the reader
struct EPUBBook: Identifiable, Hashable, Sendable {
    let id: UUID
    var title: String
    var author: String
    var language: String
    var bookDescription: String
    var coverImageURL: URL?
    var fileURL: URL
    var unzippedDirectory: URL
    var opfDirectory: URL
    var chapters: [EPUBChapter]
    var toc: [TOCItem]
    var currentChapterIndex: Int = 0

    init(
        id: UUID = UUID(),
        title: String,
        author: String = "未知作者",
        language: String = "zh",
        bookDescription: String = "",
        coverImageURL: URL? = nil,
        fileURL: URL,
        unzippedDirectory: URL,
        opfDirectory: URL,
        chapters: [EPUBChapter] = [],
        toc: [TOCItem] = [],
        currentChapterIndex: Int = 0
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.language = language
        self.bookDescription = bookDescription
        self.coverImageURL = coverImageURL
        self.fileURL = fileURL
        self.unzippedDirectory = unzippedDirectory
        self.opfDirectory = opfDirectory
        self.chapters = chapters
        self.toc = toc
        self.currentChapterIndex = currentChapterIndex
    }

    var currentChapter: EPUBChapter? {
        guard chapters.indices.contains(currentChapterIndex) else { return nil }
        return chapters[currentChapterIndex]
    }

    var progress: Double {
        guard !chapters.isEmpty else { return 0 }
        return Double(currentChapterIndex + 1) / Double(chapters.count)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: EPUBBook, rhs: EPUBBook) -> Bool {
        lhs.id == rhs.id
    }
}

/// A chapter item in the EPUB spine
struct EPUBChapter: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    let fileURL: URL
    let orderIndex: Int

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(orderIndex)
    }

    static func == (lhs: EPUBChapter, rhs: EPUBChapter) -> Bool {
        lhs.id == rhs.id && lhs.orderIndex == rhs.orderIndex
    }
}

/// Table of Contents node
struct TOCItem: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let href: String
    let targetURL: URL
    var subitems: [TOCItem] = []

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(href)
    }

    static func == (lhs: TOCItem, rhs: TOCItem) -> Bool {
        lhs.id == rhs.id && lhs.href == rhs.href
    }
}

/// A user highlight / quote and thought in a book (WeChat Read style)
struct Highlight: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var bookId: UUID
    var bookTitle: String
    var chapterIndex: Int
    var chapterTitle: String
    var text: String
    var colorHex: String
    let createdAt: Date
    var note: String?
    var updatedAt: Date?
    var source: String? // "wechat_read" or nil (local)
    var wechatBookId: String?
    var wechatBookmarkId: String?
    var wechatAuthor: String?

    var isFromWeChatRead: Bool {
        source == "wechat_read" || wechatBookmarkId != nil
    }

    var displaySource: String {
        isFromWeChatRead ? "微信读书" : "DReader"
    }

    init(
        id: UUID = UUID(),
        bookId: UUID,
        bookTitle: String = "",
        chapterIndex: Int,
        chapterTitle: String,
        text: String,
        colorHex: String = "#FFE066",
        createdAt: Date = Date(),
        note: String? = nil,
        updatedAt: Date? = nil,
        source: String? = nil,
        wechatBookId: String? = nil,
        wechatBookmarkId: String? = nil,
        wechatAuthor: String? = nil
    ) {
        self.id = id
        self.bookId = bookId
        self.bookTitle = bookTitle
        self.chapterIndex = chapterIndex
        self.chapterTitle = chapterTitle
        self.text = text
        self.colorHex = colorHex
        self.createdAt = createdAt
        self.note = note
        self.updatedAt = updatedAt
        self.source = source
        self.wechatBookId = wechatBookId
        self.wechatBookmarkId = wechatBookmarkId
        self.wechatAuthor = wechatAuthor
    }

    enum CodingKeys: String, CodingKey {
        case id, bookId, bookTitle, chapterIndex, chapterTitle, text, colorHex, createdAt, note, updatedAt
        case source, wechatBookId, wechatBookmarkId, wechatAuthor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.bookId = try container.decode(UUID.self, forKey: .bookId)
        self.bookTitle = try container.decodeIfPresent(String.self, forKey: .bookTitle) ?? ""
        self.chapterIndex = try container.decode(Int.self, forKey: .chapterIndex)
        self.chapterTitle = try container.decode(String.self, forKey: .chapterTitle)
        self.text = try container.decode(String.self, forKey: .text)
        self.colorHex = try container.decode(String.self, forKey: .colorHex)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.note = try container.decodeIfPresent(String.self, forKey: .note)
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        self.source = try container.decodeIfPresent(String.self, forKey: .source)
        self.wechatBookId = try container.decodeIfPresent(String.self, forKey: .wechatBookId)
        self.wechatBookmarkId = try container.decodeIfPresent(String.self, forKey: .wechatBookmarkId)
        self.wechatAuthor = try container.decodeIfPresent(String.self, forKey: .wechatAuthor)
    }
}
