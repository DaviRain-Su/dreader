import Foundation

/// Represents a physical Dog-Ear (折角) Bookmark in a chapter
struct Bookmark: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let bookId: UUID
    let bookTitle: String
    let chapterIndex: Int
    let chapterTitle: String
    let scrollProgress: Double
    let createdAt: Date
    var note: String?

    init(
        id: UUID = UUID(),
        bookId: UUID,
        bookTitle: String,
        chapterIndex: Int,
        chapterTitle: String,
        scrollProgress: Double = 0.0,
        createdAt: Date = Date(),
        note: String? = nil
    ) {
        self.id = id
        self.bookId = bookId
        self.bookTitle = bookTitle
        self.chapterIndex = chapterIndex
        self.chapterTitle = chapterTitle
        self.scrollProgress = scrollProgress
        self.createdAt = createdAt
        self.note = note
    }
}
