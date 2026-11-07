import SwiftUI

/// AI 导读内容视图(读伴式三分区):全书导读 / 章节导读 / 笔记。
/// 嵌入两处:AIChatPanel 的导读段(阅读中)+ BookGuideSheet 薄壳(书架入口)。
/// 生成走 PiAgentService(p guide lane),落库 LibraryDatabase.book_guides,可重新生成覆盖。
/// 问答不在这里——问答归 AIChatPanel 聊天主线(带会话历史)。
struct BookGuideContent: View {
    let book: EPUBBook
    var initialChapter: EPUBChapter? = nil
    var chineseScriptMode: ChineseScriptMode = .original
    /// 章正文提供(阅读器打开时由 ReaderViewModel 注入;书架入口为 nil,导读退化为标题级)
    var chapterBodyProvider: (() -> String)? = nil
    /// 嵌在窄面板时用紧凑字号(侧栏 320–560;书架 sheet 680)
    var compactLayout: Bool = false
    /// 追问回调(面板嵌入时注入):把导读结论作为引文送进问答流(艾德勒:导读是入口而非孤岛)
    var onFollowUp: ((String) -> Void)? = nil

    @State private var selectedTab: GuideTab = .wholeBook
    @State private var wholeGuide: BookGuide?
    @State private var chapterGuide: ChapterGuide?
    @State private var isGeneratingGuide = false
    @State private var guideError: String?
    @State private var notes: [GuideNote] = []
    @State private var newNote = ""

    enum GuideTab: String, CaseIterable, Identifiable {
        case wholeBook = "全书导读"
        case chapter = "章节导读"
        case notes = "笔记"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .wholeBook: return "book.pages"
            case .chapter: return "doc.text.magnifyingglass"
            case .notes: return "square.and.pencil"
            }
        }
    }

    private var title: String {
        ChineseScriptConverter.convert(book.title, mode: chineseScriptMode)
    }

    private var targetChapter: EPUBChapter? {
        initialChapter ?? book.currentChapter
    }

    /// 紧凑/舒展双档字号(面板 vs 书架 sheet)
    private var bodyFontSize: CGFloat { compactLayout ? 12.5 : 14 }
    private var cardPadding: CGFloat { compactLayout ? 12 : 16 }

    var body: some View {
        VStack(spacing: 0) {
            tabSelector
            Divider().opacity(0.3)
            content
        }
        .task {
            await loadOrGenerateWholeGuide()
            loadNotes()
        }
    }

    // MARK: - Tab Selector

    private var tabSelector: some View {
        HStack(spacing: 4) {
            ForEach(GuideTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.icon).font(.system(size: 11))
                        Text(tab.rawValue).font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(selectedTab == tab ? Color(hex: "#1F3FB0").opacity(0.1) : .clear)
                    .foregroundStyle(selectedTab == tab ? Color(hex: "#1F3FB0") : Color(hex: "#6D6A63"))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if selectedTab == .wholeBook || selectedTab == .chapter {
                Button {
                    Task { await regenerate() }
                } label: {
                    Label("重新生成", systemImage: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(hex: "#1F3FB0"))
                .disabled(isGeneratingGuide)
            }
        }
        .padding(.horizontal, compactLayout ? 12 : 24)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .wholeBook: wholeBookSection
        case .chapter: chapterSection
        case .notes: notesSection
        }
    }

    // MARK: - 全书导读

    private var wholeBookSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if isGeneratingGuide && wholeGuide == nil {
                    generatingBanner("正在生成全书导读…")
                }
                if let error = guideError {
                    errorBanner(error)
                }
                if let guide = wholeGuide {
                    guideCard(title: "这本书在解决什么问题", systemImage: "questionmark.circle",
                              followUpQuote: guide.whatProblem) {
                        Text(guide.whatProblem)
                    }
                    if !guide.mapEntries.isEmpty {
                        guideCard(title: "全书地图", systemImage: "map") {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(Array(guide.mapEntries.enumerated()), id: \.offset) { _, entry in
                                    FollowUpRow(
                                        quote: "全书地图「\(entry.range)」:\(entry.summary)",
                                        onFollowUp: onFollowUp
                                    ) {
                                        Text(entry.summary)
                                            .font(.system(size: bodyFontSize))
                                            .foregroundStyle(Color(hex: "#141414"))
                                    }
                                }
                            }
                        }
                    }
                    guideCard(title: "怎么读", systemImage: "book",
                              followUpQuote: guide.readingAdvice) {
                        Text(guide.readingAdvice)
                    }
                    if !guide.keyTerms.isEmpty {
                        guideCard(title: "关键概念", systemImage: "lightbulb") {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(guide.keyTerms, id: \.term) { term in
                                    FollowUpRow(
                                        quote: "关键概念「\(term.term)」:\(term.definition)",
                                        onFollowUp: onFollowUp
                                    ) {
                                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                                            Text(term.term)
                                                .font(.system(size: 11, weight: .semibold))
                                                .foregroundStyle(Color(hex: "#1F3FB0"))
                                            Text(term.definition)
                                                .font(.system(size: bodyFontSize))
                                                .foregroundStyle(Color(hex: "#141414"))
                                        }
                                    }
                                }
                            }
                        }
                    }
                } else if !isGeneratingGuide {
                    emptyState("全书导读尚未生成")
                }
            }
            .padding(compactLayout ? 14 : 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 章节导读

    private var chapterSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let chapter = targetChapter {
                    Text(ChineseScriptConverter.convert(chapter.title, mode: chineseScriptMode))
                        .font(.system(size: compactLayout ? 14 : 17, weight: .semibold, design: .serif))
                        .foregroundStyle(Color(hex: "#141414"))
                }
                if isGeneratingGuide && chapterGuide == nil {
                    generatingBanner("正在生成本章导读…")
                }
                if let error = guideError {
                    errorBanner(error)
                }
                if let guide = chapterGuide {
                    guideCard(title: "本章速览", systemImage: "doc.text",
                              followUpQuote: "本章速览:\(guide.overview)") {
                        Text(guide.overview)
                    }
                    if !guide.backgroundPoints.isEmpty {
                        guideCard(title: "背景与概念", systemImage: "books.vertical") {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(guide.backgroundPoints.enumerated()), id: \.offset) { _, point in
                                    FollowUpRow(
                                        quote: "背景要点:\(point)",
                                        onFollowUp: onFollowUp
                                    ) {
                                        HStack(alignment: .top, spacing: 6) {
                                            Circle().fill(Color(hex: "#1F3FB0")).frame(width: 4, height: 4).padding(.top, 6)
                                            Text(point).font(.system(size: bodyFontSize)).foregroundStyle(Color(hex: "#141414"))
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if !guide.socraticQuestions.isEmpty {
                        guideCard(title: "苏格拉底之问", systemImage: "questionmark.bubble") {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(Array(guide.socraticQuestions.enumerated()), id: \.offset) { idx, q in
                                    FollowUpRow(
                                        quote: "苏格拉底之问:\(q)",
                                        onFollowUp: onFollowUp
                                    ) {
                                        Text("\(idx + 1). \(q)")
                                            .font(.system(size: bodyFontSize, design: .serif))
                                            .foregroundStyle(Color(hex: "#141414"))
                                            .lineSpacing(4)
                                    }
                                }
                            }
                        }
                    }
                } else if !isGeneratingGuide {
                    VStack(spacing: 12) {
                        emptyState("本章导读尚未生成")
                        Button("生成本章导读") {
                            Task { await regenerateChapter() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(hex: "#1F3FB0"))
                    }
                }
            }
            .padding(compactLayout ? 14 : 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 笔记

    private var notesSection: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if notes.isEmpty {
                        emptyState("还没有笔记。从问答或导读中保存你的思考。")
                    }
                    ForEach(notes) { note in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(note.createdAt, style: .date)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button {
                                    deleteNote(note)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            Text(note.content)
                                .font(.system(size: bodyFontSize))
                                .foregroundStyle(Color(hex: "#141414"))
                                .textSelection(.enabled)
                        }
                        .padding(12)
                        .background(Color.white.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(compactLayout ? 14 : 20)
            }
            Divider().opacity(0.3)
            HStack(alignment: .bottom, spacing: 10) {
                TextField("记一笔…", text: $newNote, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                    .onSubmit { addNote() }
                Button {
                    addNote()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 20))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(hex: "#1F3FB0"))
                .disabled(newNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
        }
    }

    private func addNote() {
        let content = newNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        newNote = ""
        let note = GuideNote(content: content, createdAt: Date())
        notes.insert(note, at: 0)
        LibraryDatabase.shared.saveGuideNotes(notes, bookId: book.id)
    }

    private func deleteNote(_ note: GuideNote) {
        notes.removeAll { $0.id == note.id }
        LibraryDatabase.shared.saveGuideNotes(notes, bookId: book.id)
    }

    private func loadNotes() {
        notes = LibraryDatabase.shared.loadGuideNotes(bookId: book.id)
    }

    // MARK: - 复用组件

    private func guideCard<Content: View>(
        title: String, systemImage: String, followUpQuote: String? = nil, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(hex: "#1F3FB0"))
            content()
                .font(.system(size: bodyFontSize, design: .serif))
                .foregroundStyle(Color(hex: "#141414"))
                .lineSpacing(5)
            if let followUpQuote, let onFollowUp {
                Button {
                    onFollowUp(followUpQuote)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 9))
                        Text("追问这条")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundStyle(Color(hex: "#1F3FB0").opacity(0.85))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color(hex: "#1F3FB0").opacity(0.08))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Color(hex: "#6D6A63"))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func generatingBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Color(hex: "#6D6A63"))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: "#1F3FB0").opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
    }

    // MARK: - 生成

    /// 全书导读:库里已有则读,否则生成并落库
    private func loadOrGenerateWholeGuide() async {
        if let saved = LibraryDatabase.shared.loadBookGuide(bookId: book.id) {
            wholeGuide = saved
            return
        }
        await generateWholeGuide()
    }

    private func generateWholeGuide() async {
        isGeneratingGuide = true
        guideError = nil
        defer { isGeneratingGuide = false }
        do {
            // 章节要点抽样:目录 + 当前章正文开头(控制 token 预算;
            // 章正文只在当前章可取——书架入口拿不到全文,靠目录结构组织地图)
            var chapterSummaries: [String] = []
            for (idx, chapter) in book.chapters.prefix(12).enumerated() {
                chapterSummaries.append("第\(idx + 1)章「\(chapter.title)」")
            }
            if let body = chapterBodyProvider?(), !body.isEmpty {
                let head = String(body.prefix(400)).replacingOccurrences(of: "\n", with: " ")
                let currentTitle = targetChapter.map { ChineseScriptConverter.convert($0.title, mode: chineseScriptMode) } ?? ""
                chapterSummaries.append("当前章「\(currentTitle)」正文开头:\(head)…")
            }

            let prompt = """
            请为以下书籍生成一份「读伴式」全书导读,严格输出 JSON(不要解释与围栏):
            {"whatProblem":"这本书在解决什么问题,~200字","mapEntries":[{"range":"如 Chapter 0–2 或 第一部分","summary":"一句话脉络"}],"readingAdvice":"目标读者与阅读建议,~120字","keyTerms":[{"term":"术语","definition":"一句话解释"}]}

            书名:《\(book.title)》
            作者:\(book.author)
            简介:\(book.bookDescription.isEmpty ? "(无)" : String(book.bookDescription.prefix(300)))
            章节抽样:
            \(chapterSummaries.joined(separator: "\n"))
            """
            let raw = try await PiAgentService.shared.collectGuide(prompt: prompt)
            let guide = try Self.parseBookGuide(raw)
            wholeGuide = guide
            LibraryDatabase.shared.saveBookGuide(guide, bookId: book.id, model: "pi")
        } catch {
            guideError = "全书导读生成失败:\(error.localizedDescription)"
        }
    }

    private func regenerateChapter() async {
        guard let chapter = targetChapter else { return }
        isGeneratingGuide = true
        guideError = nil
        defer { isGeneratingGuide = false }
        do {
            let body = chapterBodyProvider?() ?? ""
            let prompt = """
            请为以下章节生成导读,严格输出 JSON(不要解释与围栏):
            {"chapterTitle":"章节标题","overview":"~100字核心摘要","backgroundPoints":["3个背景/概念要点"],"socraticQuestions":["1–2个苏格拉底式反思问题"]}

            书籍:《\(book.title)》
            章节:\(chapter.title)
            \(body.isEmpty ? "(正文未提供,请基于章节标题与全书语境推断)" : "正文开头:\(String(body.prefix(2400)))")
            """
            let raw = try await PiAgentService.shared.collectGuide(prompt: prompt)
            chapterGuide = try Self.parseChapterGuide(raw)
        } catch {
            guideError = "章节导读生成失败:\(error.localizedDescription)"
        }
    }

    private func regenerate() {
        Task {
            switch selectedTab {
            case .wholeBook:
                await generateWholeGuide()
            case .chapter:
                await regenerateChapter()
            default:
                break
            }
        }
    }

    // MARK: - JSON 解析(宽容:剥围栏 + 扫首个平衡对象)

    static func parseBookGuide(_ raw: String) throws -> BookGuide {
        let data = try firstJSONData(in: raw)
        let decoded = try JSONDecoder().decode(BookGuide.self, from: data)
        guard !decoded.whatProblem.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "whatProblem 为空"))
        }
        return decoded
    }

    static func parseChapterGuide(_ raw: String) throws -> ChapterGuide {
        let data = try firstJSONData(in: raw)
        return try JSONDecoder().decode(ChapterGuide.self, from: data)
    }

    private static func firstJSONData(in raw: String) throws -> Data {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "```json", with: "", options: .caseInsensitive)
        s = s.replacingOccurrences(of: "```", with: "")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = s.firstIndex(where: { $0 == "{" || $0 == "[" }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "输出中没有 JSON"))
        }
        let opening = s[start]
        let closing: Character = opening == "{" ? "}" : "]"
        var depth = 0
        var inString = false
        var escaped = false
        var i = start
        while i < s.endIndex {
            let ch = s[i]
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
            } else if ch == "\"" {
                inString = true
            } else if ch == opening {
                depth += 1
            } else if ch == closing {
                depth -= 1
                if depth == 0 {
                    return String(s[start...i]).data(using: .utf8) ?? Data()
                }
            }
            i = s.index(after: i)
        }
        throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "JSON 未闭合"))
    }
}

/// 书架入口薄壳:全屏 sheet 包 BookGuideContent(标题栏 + 关闭)。
/// 阅读中的导读走 AIChatPanel 导读段,不再用这里。
struct BookGuideSheet: View {
    let book: EPUBBook
    var initialChapter: EPUBChapter? = nil
    var chineseScriptMode: ChineseScriptMode = .original
    var chapterBodyProvider: (() -> String)? = nil

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .buttonStyle(.bordered)
                Spacer()
                Label("AI 导读 · \(ChineseScriptConverter.convert(book.title, mode: chineseScriptMode))", systemImage: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(hex: "#1F3FB0"))
                Spacer()
                // 对称占位,让标题居中
                Text(" ").font(.system(size: 13)).buttonStyle(.bordered)
            }
            .padding(.horizontal, 24)
            .frame(height: 60)
            BookGuideContent(
                book: book,
                initialChapter: initialChapter,
                chineseScriptMode: chineseScriptMode,
                chapterBodyProvider: chapterBodyProvider
            )
        }
        .background(Color(hex: "#F4F2ED"))
        .frame(minWidth: 680, minHeight: 560)
    }
}

/// 导读笔记(落 book_guides 同库的独立键)
struct GuideNote: Codable, Identifiable, Sendable, Equatable {
    var id: UUID = UUID()
    var content: String
    var createdAt: Date
}

/// 可追问行:整行内容可点,把引文送进问答流(艾德勒:导读结论应可追问而非孤岛)
private struct FollowUpRow<Content: View>: View {
    let quote: String
    let onFollowUp: ((String) -> Void)?
    @ViewBuilder let content: () -> Content

    var body: some View {
        if let onFollowUp {
            Button {
                onFollowUp(quote)
            } label: {
                content()
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("点击进问答流追问这条")
        } else {
            content()
        }
    }
}
