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
    @Bindable var agentService: PiAgentService
    let onClose: () -> Void
    /// Sanitized plain-text of the current chapter (AI can actually read this chapter)
    var chapterBodyText: (() -> String)? = nil
    /// Whole-book paragraph retrieval for the "全书" scope (query -> relevant passages)
    var retrieveBookPassages: ((String) -> [BookIndexService.IndexedParagraph])? = nil
    /// Jump-to-text in the reader (clickable AI citations)
    var onJumpToOriginalText: ((String) -> Void)? = nil
    var onSaveMessageAsNote: ((ChatMessage) -> Void)? = nil
    /// 初始段(外部入口可直达导读;默认问答)
    var initialSection: PanelSection = .chat

    /// 面板两大段:导读(读伴式三分区)/ 问答(带会话历史的聊天)
    enum PanelSection: String, CaseIterable, Identifiable {
        case guide = "导读"
        case chat = "问答"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .guide: return "book.pages"
            case .chat: return "bubble.left.and.bubble.right"
            }
        }
    }

    @State private var panelSection: PanelSection = .chat
    @State private var messages: [ChatMessage] = []
    @State private var inputText: String = ""
    @State private var showSettingsSheet: Bool = false
    @State private var currentStreamingAnswer: String = ""
    @State private var searchScope: AISearchScope = .chapter
    @State private var isBriefingExpanded: Bool = true
    /// 面板宽度(拖拽分隔条调;320–560,默认 400)
    @State private var panelWidth: CGFloat = 400
    /// 一键展开半屏(Readwise 双形态:同一会话,更多空间)
    @State private var isExpanded: Bool = false

    // 会话持久化(按书 scope;重启/切书不丢)
    @State private var sessions: [LibraryDatabase.ChatSessionMeta] = []
    @State private var currentSessionID: UUID?
    @State private var showSessionList: Bool = false

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

            // 分段:导读 / 问答(读伴式两分区融合进同一面板)
            sectionSelector

            if panelSection == .guide {
                // 导读段:读伴式三分区(全书/章节/笔记)融合进面板
                if let book {
                    BookGuideContent(
                        book: book,
                        initialChapter: currentChapter,
                        chapterBodyProvider: chapterBodyText,
                        compactLayout: true
                    )
                } else {
                    VStack(spacing: 8) {
                        Spacer()
                        Image(systemName: "sparkles")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                        Text("请先打开一本书以查看 AI 导读")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            } else {
                chatSection
            }
        }
        .frame(width: isExpanded ? (NSScreen.main?.frame.width ?? 1440) * 0.5 : panelWidth)
        .background(.ultraThinMaterial)
        .overlay(
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.3))
                .frame(width: 0.5),
            alignment: .leading
        )
        // 左缘拖拽调宽把手(320–560;展开态禁用)
        .overlay(alignment: .leading) {
            if !isExpanded {
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                panelWidth = min(560, max(320, panelWidth - value.translation.width))
                            }
                    )
            }
        }
        .sheet(isPresented: $showSettingsSheet) {
            AIAgentSettingsSheet(agentService: agentService)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("DReaderTriggerAIPrompt"))) { notif in
            if let info = notif.userInfo,
               let prompt = info["prompt"] as? String,
               let quote = info["quote"] as? String {
                panelSection = .chat
                sendCustomPrompt(prompt, quote: quote)
            }
        }
        .onAppear {
            panelSection = initialSection
            loadSessionsForCurrentBook()
        }
        .onChange(of: book?.id) { _, _ in
            // 切书:重载该书会话列表,回到最近一条或空
            loadSessionsForCurrentBook()
        }
    }

    // MARK: - Section Selector(导读 / 问答)

    private var sectionSelector: some View {
        HStack(spacing: 4) {
            ForEach(PanelSection.allCases) { section in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        panelSection = section
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: section.icon).font(.system(size: 10.5))
                        Text(section.rawValue).font(.system(size: 11.5, weight: .medium))
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(panelSection == section ? Color.primary.opacity(0.08) : .clear)
                    .foregroundStyle(panelSection == section ? Color.primary : Color.secondary)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Chat Section(问答:会话持久化 + 流式)

    private var chatSection: some View {
        VStack(spacing: 0) {
            // 会话切换条(最近会话 + 新会话)
            sessionBar

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
                                Text("正在向 \(agentService.displayName) 传输语境并思考...")
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
    }

    // MARK: - Session Bar(最近会话 + 新会话)

    private var sessionBar: some View {
        HStack(spacing: 6) {
            // 会话切换器(下拉列出该书最近会话)
            Menu {
                ForEach(sessions) { session in
                    Button {
                        switchToSession(session)
                    } label: {
                        HStack {
                            Text(session.title.isEmpty ? "未命名会话" : session.title)
                                .lineLimit(1)
                            Spacer()
                            Text(session.updatedAt, style: .relative)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if sessions.isEmpty {
                    Text("暂无历史会话")
                        .foregroundStyle(.secondary)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(currentSessionTitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.04))
                .clipShape(Capsule())
                .frame(maxWidth: 150)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("切换历史会话")

            // 新会话
            Button {
                startNewSession()
            } label: {
                Image(systemName: "plus.bubble")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("开始新会话")

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var currentSessionTitle: String {
        if let id = currentSessionID, let s = sessions.first(where: { $0.id == id }) {
            return s.title.isEmpty ? "未命名会话" : s.title
        }
        return "新会话"
    }

    // MARK: - Session Persistence

    /// 切书/初始化:重载该书会话列表,自动接最近一条
    private func loadSessionsForCurrentBook() {
        guard let book else {
            sessions = []
            currentSessionID = nil
            messages = []
            return
        }
        sessions = LibraryDatabase.shared.loadChatSessions(bookId: book.id)
        if let latest = sessions.first {
            currentSessionID = latest.id
            messages = LibraryDatabase.shared.loadChatMessages(sessionId: latest.id)
        } else {
            currentSessionID = nil
            messages = []
        }
    }

    /// 切到指定历史会话
    private func switchToSession(_ session: LibraryDatabase.ChatSessionMeta) {
        guard session.id != currentSessionID else { return }
        // 流式中的回答先落库,防止切换丢尾
        flushStreamingToSession()
        currentSessionID = session.id
        messages = LibraryDatabase.shared.loadChatMessages(sessionId: session.id)
        currentStreamingAnswer = ""
    }

    /// 开新会话(懒建:首条消息发出时才落库)
    private func startNewSession() {
        flushStreamingToSession()
        currentSessionID = nil
        messages = []
        currentStreamingAnswer = ""
        inputText = ""
    }

    /// 流式尾落库(切会话/切书前调用,防丢最后的回答)
    private func flushStreamingToSession() {
        let answer = currentStreamingAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty, let sessionID = currentSessionID, let book else { return }
        LibraryDatabase.shared.appendChatMessage(
            ChatMessage(role: .assistant, content: answer),
            sessionId: sessionID,
            bookId: book.id
        )
    }

    /// 确保有当前会话(懒建:首条消息发出时创建)
    @discardableResult
    private func ensureSession(prompt: String) -> UUID? {
        if let id = currentSessionID { return id }
        guard let book else { return nil }
        let title = String(prompt.prefix(24))
        let anchor = currentChapter.map { "\($0.title)" } ?? ""
        let id = LibraryDatabase.shared.createChatSession(
            bookId: book.id, title: title, chapterAnchor: anchor
        )
        currentSessionID = id
        sessions = LibraryDatabase.shared.loadChatSessions(bookId: book.id)
        return id
    }

    /// 重命名当前会话(弹 NSAlert 输入)
    private func renameCurrentSession(id: UUID) {
        let alert = NSAlert()
        alert.messageText = "重命名会话"
        alert.alertStyle = .informational
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.stringValue = sessions.first(where: { $0.id == id })?.title ?? ""
        alert.accessoryView = input
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            let newTitle = input.stringValue.trimmingCharacters(in: .whitespaces)
            guard !newTitle.isEmpty else { return }
            LibraryDatabase.shared.renameChatSession(id: id, title: newTitle)
            sessions = LibraryDatabase.shared.loadChatSessions(bookId: book?.id ?? UUID())
        }
    }

    /// 删除会话(当前会话删后回落最近一条或空)
    private func deleteSession(id: UUID) {
        LibraryDatabase.shared.deleteChatSession(id: id)
        sessions = LibraryDatabase.shared.loadChatSessions(bookId: book?.id ?? UUID())
        if currentSessionID == id {
            if let latest = sessions.first {
                currentSessionID = latest.id
                messages = LibraryDatabase.shared.loadChatMessages(sessionId: latest.id)
            } else {
                currentSessionID = nil
                messages = []
            }
        }
        currentStreamingAnswer = ""
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

            // 一键展开半屏(Readwise 双形态:同一会话,更多空间)
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                Image(systemName: isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "收起为侧栏" : "展开为半屏")

            // Agent Status Badge
            Button {
                showSettingsSheet = true
            } label: {
                HStack(spacing: 4) {
                    Circle()
                        .fill(connectionStatusColor)
                        .frame(width: 6, height: 6)
                    Text(agentService.displayName)
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
                    startNewSession()
                } label: {
                    Label("新会话(当前会话保留在历史)", systemImage: "plus.bubble")
                }

                // 重命名当前会话
                if let id = currentSessionID {
                    Button {
                        renameCurrentSession(id: id)
                    } label: {
                        Label("重命名当前会话…", systemImage: "pencil")
                    }
                }

                // 删除当前会话
                if let id = currentSessionID {
                    Button {
                        deleteSession(id: id)
                    } label: {
                        Label("删除当前会话", systemImage: "trash")
                    }
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
                Label("Agent: \(agentService.displayName)", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.primary.opacity(0.75))
                Label("通讯驱动: pi agent RPC(长驻子进程)", systemImage: "bolt.horizontal.fill")
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
        guard let book else { return }
        let actualQuote = quote ?? activeQuote
        let noteSource = AINoteSource(book: book, chapter: currentChapter)
        let userMsg = ChatMessage(
            role: .user,
            content: prompt,
            quoteContext: actualQuote
        )
        messages.append(userMsg)
        // 落库(懒建会话:首条消息创建,标题取首问)
        if let sessionID = ensureSession(prompt: prompt) {
            LibraryDatabase.shared.appendChatMessage(userMsg, sessionId: sessionID, bookId: book.id)
        }
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
                    bookContext += "《\(book.title)》中的相关段落：\n"
                    let currentIdx = book.currentChapterIndex
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
            bookTitle: book.title,
            author: book.author,
            chapterTitle: resolvedChapterTitle,
            activeQuote: actualQuote,
            userPrompt: resolvedPrompt,
            onToken: { token in
                currentStreamingAnswer += token
            },
            onComplete: {
                let answer = currentStreamingAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
                let finalContent = answer.isEmpty
                    ? "（未收到来自 \(agentService.displayName) 的有效回答，请检查本地环境或切换 Agent）"
                    : answer
                let assistantMsg = ChatMessage(
                    role: .assistant,
                    content: finalContent,
                    quoteContext: actualQuote,
                    noteSource: noteSource
                )
                messages.append(assistantMsg)
                if let sessionID = currentSessionID {
                    LibraryDatabase.shared.appendChatMessage(assistantMsg, sessionId: sessionID, bookId: book.id)
                }
                currentStreamingAnswer = ""
            },
            onError: { errorMsg in
                let errorMsgObj = ChatMessage(
                    role: .assistant,
                    content: "⚠️ 伴读响应异常：\(errorMsg)",
                    quoteContext: actualQuote
                )
                messages.append(errorMsgObj)
                if let sessionID = currentSessionID {
                    LibraryDatabase.shared.appendChatMessage(errorMsgObj, sessionId: sessionID, bookId: book.id)
                }
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

// MARK: - AI Agent Settings Sheet(pi agent 版)
struct AIAgentSettingsSheet: View {
    @Bindable var agentService: PiAgentService
    @Environment(\.dismiss) private var dismiss
    @State private var modelSearch: String = ""

    /// 模型清单按搜索词过滤(1448 条全列不现实;provider 前缀 + 模型名/ID 双匹配)
    private var filteredModels: [PiRPCProtocol.ModelInfo] {
        let q = modelSearch.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return agentService.availableModels }
        return agentService.availableModels.filter {
            $0.provider.localizedCaseInsensitiveContains(q)
                || $0.modelID.localizedCaseInsensitiveContains(q)
                || $0.name.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .foregroundStyle(.secondary)
                    Text("AI 伴读引擎(pi agent)")
                        .font(.headline)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.bottom, 8)

            Form {
                // 当前模型(用户要求:默认是什么模型必须可见)
                HStack {
                    Text("当前模型:")
                        .font(.system(size: 12, weight: .medium))
                    if agentService.isLoadingModels {
                        ProgressView()
                            .controlSize(.small)
                        Text("拉取中…")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else if agentService.currentModel.isEmpty {
                        Text("未知(未获取到)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(agentService.currentModel)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button("重新检测") {
                        agentService.checkConnection()
                        agentService.refreshModels()
                    }
                    .font(.system(size: 12))
                }

                Text("状态:")
                    .font(.system(size: 12))
                    .foregroundStyle(.clear)
                    .overlay(alignment: .leading) {
                        HStack {
                            Text("状态:")
                                .font(.system(size: 12))
                            Text(statusText)
                                .font(.system(size: 11))
                                .foregroundStyle(statusColor)
                        }
                    }

                Divider()

                // 模型选择:搜索过滤 + 列表(点击即切换,全 lane 生效)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "cpu")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text("切换模型(聊天 / 导读 / 翻译共用)")
                            .font(.system(size: 12, weight: .medium))
                    }
                    TextField("搜索 provider 或模型名(如 magpie、glm、claude)…", text: $modelSearch)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))

                    if agentService.availableModels.isEmpty, !agentService.isLoadingModels {
                        Text("模型清单为空:请先运行 `pi` 完成登录,或点「重新检测」。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        List(filteredModels.prefix(400)) { model in
                            Button {
                                agentService.selectModel(provider: model.provider, modelID: model.modelID)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(model.displayLabel)
                                            .font(.system(size: 11.5))
                                            .lineLimit(1)
                                        Text(model.id)
                                            .font(.system(size: 9.5, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if model.id == agentService.currentModel {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .listStyle(.plain)
                        .frame(height: 180)
                    }
                }

                Text("模型与密钥由 pi 统一管理:运行 `pi` 一次完成登录/配置,或在 ~/.pi/agent/models.json 配置 provider。DReader 无需单独配置。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            // Connection Help Note
            VStack(alignment: .leading, spacing: 6) {
                Text("💡 pi agent 架构:")
                    .font(.system(size: 12, weight: .semibold))
                Text("• 4 条常驻 RPC 通道:聊天 1 + 导读 1 + 翻译 2,互不阻塞。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("• 模型切换对全部通道生效;停止翻译不影响聊天。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("• 安装:curl -fsSL https://pi.dev/install.sh | sh")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            agentService.checkConnection()
            agentService.refreshModels()
        }
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
