import Foundation

/// Supported online book sources
enum OnlineBookSource: String, CaseIterable, Identifiable, Codable, Sendable {
    case openLibrary = "Open Library 公开馆藏"
    case gutenberg = "古腾堡计划 (Gutenberg)"
    case zlibrary = "Z-Library 专属云书库"
    case opds = "OPDS 自建书馆"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .openLibrary: return "building.columns.fill"
        case .gutenberg: return "book.closed.fill"
        case .zlibrary: return "books.vertical.fill"
        case .opds: return "server.rack"
        }
    }

    var badgeColorHex: String {
        switch self {
        case .openLibrary: return "#2563EB"
        case .gutenberg: return "#059669"
        case .zlibrary: return "#7C3AED"
        case .opds: return "#0E7490"
        }
    }

    var requiresLogin: Bool {
        switch self {
        case .openLibrary, .gutenberg, .opds: return false
        case .zlibrary: return true
        }
    }
}

/// Represents an online book searchable and downloadable from the web
struct OnlineBookItem: Identifiable, Sendable {
    var id: String
    var title: String
    var author: String
    var source: OnlineBookSource
    var coverURL: URL?
    var downloadURL: URL?
    var candidateURLs: [URL]
    var gutenbergID: String?
    var internetArchiveID: String?
    var fileExtension: String       // e.g. "epub"
    var fileSizeFormatted: String?  // e.g. "1.8 MB"
    var publishYear: String?        // e.g. "1854"
    var language: String?           // e.g. "中文", "en"
    var isPublicDomain: Bool
    var description: String?

    init(
        id: String = UUID().uuidString,
        title: String,
        author: String,
        source: OnlineBookSource,
        coverURL: URL? = nil,
        downloadURL: URL? = nil,
        candidateURLs: [URL] = [],
        gutenbergID: String? = nil,
        internetArchiveID: String? = nil,
        fileExtension: String = "epub",
        fileSizeFormatted: String? = nil,
        publishYear: String? = nil,
        language: String? = nil,
        isPublicDomain: Bool = true,
        description: String? = nil
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.source = source
        self.coverURL = coverURL
        self.downloadURL = downloadURL
        self.candidateURLs = candidateURLs.isEmpty ? (downloadURL.map { [$0] } ?? []) : candidateURLs
        self.gutenbergID = gutenbergID
        self.internetArchiveID = internetArchiveID
        self.fileExtension = fileExtension
        self.fileSizeFormatted = fileSizeFormatted
        self.publishYear = publishYear
        self.language = language
        self.isPublicDomain = isPublicDomain
        self.description = description
    }

    var hasDownloadableContent: Bool {
        downloadURL != nil || !candidateURLs.isEmpty || (gutenbergID != nil && gutenbergID != "0") || ChineseClassicsRegistry.shared.hasClassic(title: title)
    }
}

/// Z-Library User Account & Quota State
struct ZLibraryUserAccount: Codable, Sendable {
    var email: String
    var userKey: String         // rem_token / user_key
    var dailyLimit: Int         // e.g. 10
    var downloadsToday: Int     // e.g. 2
    var isLoggedIn: Bool

    init(
        email: String = "",
        userKey: String = "",
        dailyLimit: Int = 10,
        downloadsToday: Int = 0,
        isLoggedIn: Bool = false
    ) {
        self.email = email
        self.userKey = userKey
        self.dailyLimit = dailyLimit
        self.downloadsToday = downloadsToday
        self.isLoggedIn = isLoggedIn
    }

    var remainingQuota: Int {
        max(0, dailyLimit - downloadsToday)
    }
}
