import SwiftUI
import AppKit

enum AISearchScope: String, CaseIterable, Identifiable {
    case chapter = "本章"
    case book = "全书"
    case library = "书架脑库"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .chapter: return "book.pages"
        case .book: return "book"
        case .library: return "books.vertical.fill"
        }
    }
}

struct AIChatPanel: View {
    let book: EPUBBook?
    let currentChapter: EPUBChapter?
    var allBooks: [EPUBBook] = []
    @Binding var activeQuote: String?
    @Bindable var agentService: AIAgentService
    let onClose: () -> Void
    /// Sanitized plain-text of the current chapter (AI can actually read this chapter)
    var chapterBodyText: (() -> String)? = nil
    /// Whole-book paragraph retrieval for the "全书" scope (query -> relevant passages)
    var retrieveBookPassages: ((String) -> [BookIndexService.IndexedParagraph])? = nil
    /// Jump-to-text in the reader (clickable AI citations)
    var onJumpToOriginalText: ((String) -> Void)? = nil
    var onSaveMessageAsNote: ((ChatMessage) -> Void)? = nil

    @State private var messages: [ChatMessage] = []
    @State private var inputText: String = ""
    @State private var showSettingsSheet: Bool = false
    @State private var currentStreamingAnswer: String = ""
    @State private var searchScope: AISearchScope = .chapter
    @State private var isBriefingExpanded: Bool = true

    private let quickPrompts: [(title: String, icon: String, prompt: String)] = [
        ("深度解析", "sparkles", "请结合全书语境，深入剖析这段文字的思想内涵与深层寓意"),
        ("核心要点", "list.bullet.rectangle.portrait", "请提炼出这段内容最重要的3个核心论点"),
        ("通俗比喻", "lightbulb.fill", "请用通俗生动的现代生活比喻解释作者的核心观点"),
        ("反思思辨", "questionmark.bubble.fill", "对于作者这里的论述，是否存在反向视角或批判性思辨？"),
        ("现实印证", "globe.americas.fill", "能结合当代科技发展或社会现实举一个具体的案例来印证吗？")
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerBar

            // Scope Selector Bar (Chapter / Full Book / Library RAG)
            scopeSelectorBar

            Divider()
                .opacity(0.3)

            // Active Quote Context Banner (if any)
            if let quote = activeQuote, !quote.isEmpty {
                activeQuoteBanner(quote)
            }

            // Messages List
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        // Smart Chapter Pre-reading Briefing Card
                        chapterBriefingCard

                        if messages.isEmpty && currentStreamingAnswer.isEmpty && !agentService.isGenerating {
                            emptyStateView
                        }

                        ForEach(messages) { msg in
                            MessageRow(message: msg, onJumpToQuotation: { quoted in
                                onJumpToOriginalText?(quoted)
                            }, onSaveAsNote: { message in
                                onSaveMessageAsNote?(message)
                            })
                            .id(msg.id)
                        }

                        // Thinking placeholder before tokens arrive
                        if agentService.isGenerating && currentStreamingAnswer.isEmpty {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("正在向 \(agentService.currentPreset.name) 传输语境并思考...")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .id("thinking-placeholder")
                        }

                        // Live Streaming Message
                        if !currentStreamingAnswer.isEmpty {
                            LiveStreamingRow(text: currentStreamingAnswer)
                                .id("streaming-row")
                        }
                    }
                    .padding(16)
                }
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .onChange(of: currentStreamingAnswer) { _, _ in
                    proxy.scrollTo("streaming-row", anchor: .bottom)
                }
            }

            Divider()

            // Quick Prompt Chips
            quickPromptChipsBar

            // Input Bar
            inputBar
        }
        .frame(minWidth: 280, idealWidth: 320, maxWidth: 360)
        .background(.ultraThinMaterial)
        .overlay(
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.3))
                .frame(width: 0.5),
            alignment: .leading
        )
        .sheet(isPresented: $showSettingsSheet) {
            AIAgentSettingsSheet(agentService: agentService)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("DReaderTriggerAIPrompt"))) { notif in
            if let info = notif.userInfo,
               let prompt = info["prompt"] as? String,
               let quote = info["quote"] as? String {
                sendCustomPrompt(prompt, quote: quote)
            }
        }
    }

    // MARK: - Header
    private var headerBar: some View {
        HStack(spacing: 6) {
            // Title & Role Chip —— 无彩 chrome，角色芯片为灰阶玻璃
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)

                Text("AI 伴读")
                    .font(.system(size: 13, weight: .bold))

                Menu {
                    ForEach(AIAgentRole.allCases) { role in
                        Button {
                            agentService.role = role
                        } label: {
                            Label(role.rawValue, systemImage: role.icon)
                        }
                    }
                } label: {
                    HStack(spacing: 2) {
                        Text(agentService.role.rawValue)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary.opacity(0.8))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            Spacer()

            // Agent Status Badge
            Button {
                showSettingsSheet = true
            } label: {
                HStack(spacing: 4) {
                    Circle()
                        .fill(connectionStatusColor)
                        .frame(width: 6, height: 6)
                    Text(agentService.currentPreset.name)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2.5)
                .background(Color.primary.opacity(0.04))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("切换伴读 Agent 与模型配置")

            // More Options Menu (Clear, Settings)
            Menu {
                Button {
                    showSettingsSheet = true
                } label: {
                    Label("Agent 服务设置...", systemImage: "slider.horizontal.3")
                }

                Divider()

                Button {
                    messages.removeAll()
                    currentStreamingAnswer = ""
                } label: {
                    Label("清空当前对话", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
            .menuStyle(.borderlessButton)
            .help("更多伴读选项")

            // Close Button
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("折叠 AI 伴读面板")
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .overlay(
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.3))
                .frame(height: 0.5),
            alignment: .bottom
        )
    }

    private var connectionStatusColor: Color {
        switch agentService.connectionStatus {
        case .connected: return .green
        case .checking: return .orange
        case .failed: return .red
        case .untested: return .gray
        }
    }

    // MARK: - Scope Selector Bar
    private var scopeSelectorBar: some View {
        HStack {
            HStack(spacing: 2) {
                ForEach(AISearchScope.allCases) { scope in
                    Button {
                        withAnimation(.easeInOut(duration: 0.14)) {
                            searchScope = scope
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: scope.icon)
                                .font(.system(size: 8.5))
                            Text(scope.rawValue)
                                .font(.system(size: 10, weight: searchScope == scope ? .semibold : .regular))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(searchScope == scope ? Color.primary.opacity(0.1) : Color.clear)
                        .foregroundStyle(searchScope == scope ? Color.primary.opacity(0.8) : Color.secondary)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(Color.primary.opacity(0.04))
            .clipShape(Capsule())

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    // MARK: - Active Quote Banner
    private func activeQuoteBanner(_ quote: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "quote.opening")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(quote)
                    .font(.system(size: 12))
                    .lineLimit(3)
                    .foregroundStyle(.primary)

                HStack {
                    Text("\(quote.count) 字 · 选区提问")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            Spacer()

            Button {
                activeQuote = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Chapter Pre-reading Briefing (Smart Background Briefing)
    private var currentChapterBriefing: ChapterBriefing? {
        guard let book = book, let chapter = currentChapter else { return nil }
        return ChapterBriefingService.shared.getBriefing(
            bookTitle: book.title,
            chapterTitle: chapter.title,
            chapterIndex: book.currentChapterIndex
        )
    }

    @ViewBuilder
    private var chapterBriefingCard: some View {
        if let briefing = currentChapterBriefing {
            VStack(alignment: .leading, spacing: 8) {
                // Header toggle
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isBriefingExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.secondary)

                        Text("本章导读前瞻 · 背景速览")
                            .font(.system(size: 11.5, weight: .bold))
                            .foregroundStyle(Color.primary)

                        Spacer()

                        Image(systemName: isBriefingExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)

                if isBriefingExpanded {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(briefing.overview)
                            .font(.system(size: 11, design: .serif))
                            .foregroundStyle(Color.primary.opacity(0.88))
                            .lineSpacing(2)

                        // 3 Background Points
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(briefing.backgroundPoints, id: \.self) { pt in
                                HStack(alignment: .top, spacing: 5) {
                                    Text("•")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.secondary)
                                    Text(pt)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .lineSpacing(1.5)
                                }
                            }
                        }
                        .padding(7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.03))
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                        // Action button
                        Button {
                            sendCustomPrompt("请为我深度导读当前章节《\(briefing.chapterTitle)》，剖析作者的核心意图与时代背景。")
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "bubble.left.and.text.bubble.right.fill")
                                    .font(.system(size: 9))
                                Text("向 AI 探讨本章脉络")
                                    .font(.system(size: 10.5, weight: .medium))
                            }
                            .foregroundStyle(Color.primary.opacity(0.75))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Color.primary.opacity(0.06))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 2)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.035))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 0.6)
            )
        }
    }

    // MARK: - Empty State
    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 32))
                .foregroundStyle(.secondary.opacity(0.6))
                .padding(.top, 28)

            Text("AI 伴读助手")
                .font(.system(size: 16, weight: .semibold))

            Text("在正文中【选中文本】可一键解释、批判思辨或深度提问，或在下方直接向本地 Agent 发送问题。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            VStack(alignment: .leading, spacing: 8) {
                Label("Agent: \(agentService.currentPreset.name)", systemImage: agentService.currentPreset.iconName)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.primary.opacity(0.75))
                Label("通讯驱动: \(agentService.currentPreset.driverType.rawValue)", systemImage: "bolt.horizontal.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: - Quick Prompt Chips Bar
    private var quickPromptChipsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(quickPrompts, id: \.title) { item in
                    Button {
                        sendCustomPrompt(item.prompt)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: item.icon)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary.opacity(0.8))
                            Text(item.title)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.04))
                        .clipShape(Capsule())
                        .overlay(
                            Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    // MARK: - Input Bar
    private var inputBar: some View {
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                TextEditor(text: $inputText)
                    .font(.system(size: 13))
                    .frame(minHeight: 36, maxHeight: 90)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                    )

                if agentService.isGenerating {
                    Button {
                        agentService.stopGeneration()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help("停止生成")
                } else {
                    Button {
                        handleSend()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary.opacity(0.5) : Color.primary.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: [])
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Send Action
    func sendCustomPrompt(_ prompt: String, quote: String? = nil) {
        let actualQuote = quote ?? activeQuote
        let noteSource = AINoteSource(book: book, chapter: currentChapter)
        let userMsg = ChatMessage(
            role: .user,
            content: prompt,
            quoteContext: actualQuote
        )
        messages.append(userMsg)
        inputText = ""
        currentStreamingAnswer = ""

        var resolvedPrompt = prompt
        var resolvedChapterTitle = currentChapter?.title ?? "当前章节"

        switch searchScope {
        case .library:
            resolvedChapterTitle = "【全书架跨书智能脑库检索】"
            var libContext = "\n\n【用户书架藏书目录】：\n"
            for b in allBooks {
                libContext += "- 《\(b.title)》 作者：\(b.author)，共 \(b.chapters.count) 章\n"
            }
            libContext += "请站在全书架全局宏观视角，融会贯通书架中各名著的思想脉络，进行跨文本深度对照与综合剖析。"
            resolvedPrompt = prompt + libContext

        case .book:
            resolvedChapterTitle = "【全书全局视角】" + (currentChapter?.title ?? "")
            var bookContext = "\n\n【本书全文语境检索（从全书段落索引中精准命中）】：\n"
            if book != nil {
                let passages = retrieveBookPassages?(prompt) ?? []
                if !passages.isEmpty {
                    bookContext += "《\(book?.title ?? "")》中的相关段落：\n"
                    let currentIdx = book?.currentChapterIndex ?? -1
                    for (i, passage) in passages.enumerated() {
                        let chapterLabel = passage.chapterTitle.isEmpty ? "第\(passage.chapterIndex + 1)章" : passage.chapterTitle
                        let isCurrent = passage.chapterIndex == currentIdx ? "（当前章节）" : ""
                        let clipped = passage.text.count > 260 ? String(passage.text.prefix(260)) + "…" : passage.text
                        bookContext += "\n【段落 \(i + 1) · 「\(chapterLabel)」\(isCurrent)】\n\(clipped)\n"
                    }
                } else {
                    bookContext += "（全书索引尚未构建完成，请稍候重试提问。）\n"
                }
                bookContext += "\n——检索结束。请优先引用上方段落回答；若问题更贴近当前章节，可结合当前章节全文。"
            }
            // Always append current-chapter full text as grounding
            if let chapterText = chapterBodyText?(), !chapterText.isEmpty {
                bookContext += "\n\n【当前章节全文】：\n\(chapterText)"
            }
            resolvedPrompt = prompt + bookContext

        case .chapter:
            // Inject current-chapter full text so the AI truly reads the chapter
            if let chapterText = chapterBodyText?(), !chapterText.isEmpty {
                resolvedPrompt = prompt + "\n\n【当前章节全文（AI 请直接依据原文回答）】：\n\(chapterText)"
            }
        }

        agentService.sendMessage(
            history: messages,
            bookTitle: book?.title ?? "未知书名",
            author: book?.author ?? "未知作者",
            chapterTitle: resolvedChapterTitle,
            activeQuote: actualQuote,
            userPrompt: resolvedPrompt,
            onToken: { token in
                currentStreamingAnswer += token
            },
            onComplete: {
                let answer = currentStreamingAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !answer.isEmpty {
                    messages.append(ChatMessage(
                        role: .assistant,
                        content: answer,
                        quoteContext: actualQuote,
                        noteSource: noteSource
                    ))
                } else {
                    messages.append(ChatMessage(
                        role: .assistant,
                        content: "（未收到来自 \(agentService.currentPreset.name) 的有效回答，请检查本地环境或切换 Agent）",
                        quoteContext: actualQuote,
                        noteSource: noteSource
                    ))
                }
                currentStreamingAnswer = ""
            },
            onError: { errorMsg in
                messages.append(ChatMessage(
                    role: .assistant,
                    content: "⚠️ 伴读响应异常：\(errorMsg)",
                    quoteContext: actualQuote
                ))
                currentStreamingAnswer = ""
            }
        )
    }

    private func handleSend() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sendCustomPrompt(trimmed)
    }
}

// MARK: - Message Row
private struct MessageRow: View {
    let message: ChatMessage
    var onJumpToQuotation: ((String) -> Void)? = nil
    var onSaveAsNote: ((ChatMessage) -> Void)? = nil

    @State private var savedFeedback: Bool = false

    /// Extracts verbatim quotations from AI markdown answers so they become
    /// clickable "jump to text" chips (in both 「…」 and "…" styles).
    private var quotablePassages: [String] {
        guard message.role == .assistant else { return [] }
        let patterns = ["「([^」]{6,80})」", "『([^』]{6,80})』", "\u{201c}([^\u{201d}]{6,80})\u{201d}"]
        var seen = Set<String>()
        var results: [String] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = message.content as NSString
            regex.enumerateMatches(in: message.content, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                guard let match, match.numberOfRanges >= 2 else { return }
                let quote = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                guard quote.count >= 6, !seen.contains(quote) else { return }
                seen.insert(quote)
                results.append(quote)
            }
            if results.count >= 5 { break }
        }
        return Array(results.prefix(5))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.role == .user {
                Spacer(minLength: 32)
                VStack(alignment: .trailing, spacing: 4) {
                    if let quote = message.quoteContext {
                        Text("“\(quote.prefix(50))...”")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(6)
                            .background(Color.primary.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    Text(message.content)
                        .font(.system(size: 13))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.primary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text("AI 导读")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.content, forType: .string)
                        } label: {
                            HStack(spacing: 2) {
                                Image(systemName: "doc.on.doc")
                                Text("复制")
                            }
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)

                        // 一键把 AI 解读存为书内笔记（进入划线库、iCloud 备份与 MCP）
                        if let save = onSaveAsNote, message.noteSource != nil {
                            Button {
                                save(message)
                                savedFeedback = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    savedFeedback = false
                                }
                            } label: {
                                HStack(spacing: 2) {
                                    Image(systemName: savedFeedback ? "checkmark.circle.fill" : "square.and.arrow.down")
                                    Text(savedFeedback ? "已存入" : "存为笔记")
                                }
                                .font(.system(size: 10))
                                .foregroundStyle(savedFeedback ? Color.green : Color.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("把这条 AI 解读保存到本书的划线与思考库")
                        }
                    }

                    MarkdownContentView(markdown: message.content)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.primary.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
                        )

                    if !quotablePassages.isEmpty {
                        // Clickable citation chips: jump to the exact original passage
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(Array(quotablePassages.enumerated()), id: \.offset) { _, quote in
                                    Button {
                                        onJumpToQuotation?(quote)
                                    } label: {
                                        HStack(spacing: 3) {
                                            Image(systemName: "text.magnifyingglass")
                                                .font(.system(size: 8))
                                            Text("回原文 · \(quote.prefix(18))…")
                                                .lineLimit(1)
                                        }
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.primary.opacity(0.05))
                                        .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                    .help("跳转并高亮原文出处")
                                }
                            }
                            .padding(.horizontal, 2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Spacer(minLength: 24)
            }
        }
    }
}

// MARK: - Live Streaming Row
private struct LiveStreamingRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("AI 正在实时流式生成...")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                MarkdownContentView(markdown: text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                    )
            }
            Spacer(minLength: 24)
        }
    }
}

// MARK: - AI Agent Settings Sheet
struct AIAgentSettingsSheet: View {
    @Bindable var agentService: AIAgentService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .foregroundStyle(.secondary)
                    Text("配置 ACP (Agent Client Protocol) 客户端")
                        .font(.headline)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.bottom, 8)

            Form {
                Picker("选择伴读 Agent:", selection: $agentService.currentPreset) {
                    ForEach(ACPAgentPreset.allPresets) { p in
                        HStack {
                            Image(systemName: p.iconName)
                            Text(p.name)
                        }
                        .tag(p)
                    }
                }
                .onChange(of: agentService.currentPreset) { _, newP in
                    agentService.selectPreset(newP)
                }

                HStack {
                    Text("驱动类型:")
                        .font(.system(size: 11, weight: .medium))
                    Text(agentService.currentPreset.driverType.rawValue)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Text(agentService.currentPreset.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                if agentService.currentPreset.driverType == .acpStdio || agentService.currentPreset.driverType == .cliStreaming {
                    TextField("执行命令:", text: $agentService.customCommand)
                        .textFieldStyle(.roundedBorder)
                        .help("如 `grok agent stdio`、`kimi acp`、`pi -p`、`claude -p` 等")
                } else if agentService.currentPreset.driverType == .httpAdapter {
                    TextField("服务接口地址:", text: $agentService.customCommand)
                        .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Text("状态:")
                        .font(.system(size: 12))
                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(statusColor)
                }

                Picker("伴读思考角色:", selection: $agentService.role) {
                    ForEach(AIAgentRole.allCases) { role in
                        Label(role.rawValue, systemImage: role.icon).tag(role)
                    }
                }
            }

            // Connection Help Note
            VStack(alignment: .leading, spacing: 6) {
                Text("💡 支持的多 Agent 接入矩阵：")
                    .font(.system(size: 12, weight: .semibold))
                Text("• **Grok**：xAI 官方原生 ACP (Agent Client Protocol) 协议接口 (`grok agent stdio`)。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("• **Kimi**：Moonshot Kimi Code 原生 ACP 协议服务 (`kimi acp`)。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("• **Claude Code**：Anthropic 官方 Claude Code CLI 流式驱动 (`claude -p`)。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("• **Pi / Codex / Cursor**：支持本地 Pi CLI (`pi -p`)、Codex CLI (`codex exec`) 及 Cursor Agent (`agent -p`)。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("• **内置引擎 / 本地模型**：支持离线伴读引擎与 Ollama / LM Studio 本地模型服务。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(20)
        .frame(width: 520)
    }

    private var statusText: String {
        switch agentService.connectionStatus {
        case .connected(let s): return "🟢 \(s)"
        case .checking: return "🟠 正在探测连接..."
        case .failed(let s): return "🔴 \(s)"
        case .untested: return "⚪️ 待检测"
        }
    }

    private var statusColor: Color {
        switch agentService.connectionStatus {
        case .connected: return .green
        case .checking: return .orange
        case .failed: return .red
        case .untested: return .secondary
        }
    }
}
