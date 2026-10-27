import Foundation

/// Manages dual-language interlinear paragraph translations and persistent disk caching
@Observable
final class BilingualTranslationService: @unchecked Sendable {
    static let shared = BilingualTranslationService()

    // In-memory cache: [bookTitle: [chapterIndex: [paragraphIndex: Chinese translation]]]
    private var memoryCache: [String: [Int: [Int: String]]] = [:]
    private let cacheDirectory: URL
    private let lock = NSLock()

    var isTranslatingChapter: Bool = false
    var currentProgressRatio: Double = 0.0 // 0.0 to 1.0

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.cacheDirectory = appSupport.appendingPathComponent("DReader/BilingualCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Cache Retrieval

    func getCachedTranslations(bookTitle: String, chapterIndex: Int) -> [Int: String]? {
        lock.lock()
        defer { lock.unlock() }

        let cleanTitle = sanitizeTitle(bookTitle)

        // 1. Check memory cache
        if let bookCache = memoryCache[cleanTitle], let chapterCache = bookCache[chapterIndex], !chapterCache.isEmpty {
            return chapterCache
        }

        // 2. Check disk cache
        let fileURL = cacheDirectory.appendingPathComponent("\(cleanTitle)_ch\(chapterIndex).json")
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return nil
        }

        var result: [Int: String] = [:]
        for (k, v) in dict {
            if let idx = Int(k) {
                result[idx] = v
            }
        }

        if memoryCache[cleanTitle] == nil {
            memoryCache[cleanTitle] = [:]
        }
        memoryCache[cleanTitle]?[chapterIndex] = result
        return result
    }

    // MARK: - Save Translation

    func saveTranslation(
        bookTitle: String,
        chapterIndex: Int,
        paragraphIndex: Int,
        translation: String
    ) {
        lock.lock()
        defer { lock.unlock() }

        let cleanTitle = sanitizeTitle(bookTitle)
        if memoryCache[cleanTitle] == nil {
            memoryCache[cleanTitle] = [:]
        }
        if memoryCache[cleanTitle]?[chapterIndex] == nil {
            memoryCache[cleanTitle]?[chapterIndex] = [:]
        }
        memoryCache[cleanTitle]?[chapterIndex]?[paragraphIndex] = translation

        // Persist to disk asynchronously
        guard let chapterDict = memoryCache[cleanTitle]?[chapterIndex] else { return }
        let stringKeyedDict = chapterDict.reduce(into: [String: String]()) { acc, pair in
            acc["\(pair.key)"] = pair.value
        }

        Task.detached(priority: .background) { [cacheDir = self.cacheDirectory] in
            if let data = try? JSONEncoder().encode(stringKeyedDict) {
                let fileURL = cacheDir.appendingPathComponent("\(cleanTitle)_ch\(chapterIndex).json")
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }

    // MARK: - Translate Single Paragraph with Active Agent

    func translateParagraph(
        text: String,
        bookTitle: String,
        chapterTitle: String,
        chapterIndex: Int,
        paragraphIndex: Int,
        agentService: AIAgentService
    ) async -> String {
        // If already cached, return immediately
        if let cached = getCachedTranslations(bookTitle: bookTitle, chapterIndex: chapterIndex)?[paragraphIndex] {
            return cached
        }

        do {
            let translation = try await agentService.translate(
                text: text,
                bookTitle: bookTitle,
                chapterTitle: chapterTitle
            )
            saveTranslation(
                bookTitle: bookTitle,
                chapterIndex: chapterIndex,
                paragraphIndex: paragraphIndex,
                translation: translation
            )
            return translation
        } catch {
            let fallback = EmbeddedTranslationEngine.shared.translate(text: text, bookTitle: bookTitle)
            saveTranslation(
                bookTitle: bookTitle,
                chapterIndex: chapterIndex,
                paragraphIndex: paragraphIndex,
                translation: fallback
            )
            return fallback
        }
    }

    // MARK: - Translate Entire Chapter with Progress Callback

    func translateEntireChapter(
        paragraphs: [(index: Int, text: String)],
        bookTitle: String,
        chapterTitle: String,
        chapterIndex: Int,
        agentService: AIAgentService,
        onParagraphTranslated: @escaping @MainActor (Int, String) -> Void
    ) async {
        guard !paragraphs.isEmpty else { return }

        await MainActor.run {
            self.isTranslatingChapter = true
            self.currentProgressRatio = 0.0
        }

        defer {
            Task { @MainActor in
                self.isTranslatingChapter = false
                self.currentProgressRatio = 1.0
            }
        }

        let total = Double(paragraphs.count)
        var completedCount = 0.0

        for item in paragraphs {
            let trans = await translateParagraph(
                text: item.text,
                bookTitle: bookTitle,
                chapterTitle: chapterTitle,
                chapterIndex: chapterIndex,
                paragraphIndex: item.index,
                agentService: agentService
            )

            completedCount += 1.0
            let ratio = completedCount / total

            await MainActor.run {
                self.currentProgressRatio = ratio
                onParagraphTranslated(item.index, trans)
            }
        }
    }

    private func sanitizeTitle(_ title: String) -> String {
        title.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: " ", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
