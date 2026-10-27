import Foundation

/// Kindle-style Book X-Ray: Character genealogies, key concepts, and narrative timeline
struct BookXRayData: Codable, Sendable {
    var bookTitle: String
    var characters: [XRayCharacter]
    var concepts: [XRayConcept]
    var timeline: [XRayEvent]

    init(
        bookTitle: String,
        characters: [XRayCharacter] = [],
        concepts: [XRayConcept] = [],
        timeline: [XRayEvent] = []
    ) {
        self.bookTitle = bookTitle
        self.characters = characters
        self.concepts = concepts
        self.timeline = timeline
    }
}

struct XRayCharacter: Identifiable, Codable, Sendable {
    var id: UUID
    var name: String
    var aliases: [String]
    var role: String           // e.g. "主人公", "象征角色", "对话者", "反派"
    var identity: String       // e.g. "B612小行星唯一的居民，金发孩童"
    var description: String    // Deep character background
    var keyTraits: [String]    // e.g. ["纯真", "探索", "责任", "执着"]
    var firstAppearanceChapter: String
    var chapterIndex: Int
    var importanceLevel: Int   // 1 to 3 (3 = Core protagonist)

    init(
        id: UUID = UUID(),
        name: String,
        aliases: [String] = [],
        role: String,
        identity: String,
        description: String,
        keyTraits: [String] = [],
        firstAppearanceChapter: String,
        chapterIndex: Int = 0,
        importanceLevel: Int = 3
    ) {
        self.id = id
        self.name = name
        self.aliases = aliases
        self.role = role
        self.identity = identity
        self.description = description
        self.keyTraits = keyTraits
        self.firstAppearanceChapter = firstAppearanceChapter
        self.chapterIndex = chapterIndex
        self.importanceLevel = importanceLevel
    }
}

struct XRayConcept: Identifiable, Codable, Sendable {
    var id: UUID
    var term: String
    var category: String       // e.g. "核心哲学", "文学象征", "时代制度", "历史术语"
    var shortDefinition: String
    var inDepthExplanation: String
    var representativeQuotes: [String]

    init(
        id: UUID = UUID(),
        term: String,
        category: String,
        shortDefinition: String,
        inDepthExplanation: String,
        representativeQuotes: [String] = []
    ) {
        self.id = id
        self.term = term
        self.category = category
        self.shortDefinition = shortDefinition
        self.inDepthExplanation = inDepthExplanation
        self.representativeQuotes = representativeQuotes
    }
}

struct XRayEvent: Identifiable, Codable, Sendable {
    var id: UUID
    var title: String
    var chapterTitle: String
    var chapterIndex: Int
    var summary: String
    var significance: String

    init(
        id: UUID = UUID(),
        title: String,
        chapterTitle: String,
        chapterIndex: Int,
        summary: String,
        significance: String
    ) {
        self.id = id
        self.title = title
        self.chapterTitle = chapterTitle
        self.chapterIndex = chapterIndex
        self.summary = summary
        self.significance = significance
    }
}
