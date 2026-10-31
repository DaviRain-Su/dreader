import SwiftUI

/// 全书库划线与思考回顾中心——书架层整页（与在线书库同一套页面化交互，入口点击即整窗切换）。
struct GlobalNotebooksPageView: View {
    @Bindable var viewModel: ReaderViewModel
    let onClose: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedBookTitle: String? = nil // nil = All books
    @State private var sourceFilter: HighlightSourceFilter = .all
    @State private var searchQuery: String = ""
    @State private var editingHighlightId: UUID? = nil
    @State private var editingThoughtText: String = ""
    @State private var quoteCardHighlight: Highlight? = nil
    @State private var showExportToast: Bool = false
    @State private var exportToastMessage: String = ""
    @State private var showReviewSession: Bool = false
    @State private var highlightTick: Int = 0 // bump to refresh due-count badge

    enum HighlightSourceFilter: String, CaseIterable, Identifiable {
        case all = "全部来源"
        case dreader = "DReader 本地"
        case wechat = "微信读书"
        var id: String { rawValue }
    }

    // Book Grouping Item
    struct BookNoteGroup: Identifiable, Hashable {
        var id: String { title }
        let title: String
        let author: String
        let highlightCount: Int
        let thoughtCount: Int
        let isWeChat: Bool
    }

    /// 页面底色：与在线书库整页同一套暖纸色，避免沿用弹窗的 ultraThinMaterial 观感
    private var backgroundColor: Color {
        colorScheme == .dark
            ? Color(hex: "#171310")
            : Color(hex: "#F3EDE2")
    }

    private var allBookGroups: [BookNoteGroup] {        var map: [String: (author: String, highlights: Int, thoughts: Int, isWeChat: Bool)] = [:]
        for h in viewModel.highlights {
            let t = h.bookTitle.isEmpty ? "未命名书籍" : h.bookTitle
            var entry = map[t] ?? (author: h.wechatAuthor ?? "", highlights: 0, thoughts: 0, isWeChat: false)
            entry.highlights += 1
            if let note = h.note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                entry.thoughts += 1
            }
            if h.isFromWeChatRead {
                entry.isWeChat = true
            }
            if entry.author.isEmpty, let a = h.wechatAuthor {
                entry.author = a
            }
            map[t] = entry
        }

        return map.map { (title, info) in
            BookNoteGroup(
                title: title,
                author: info.author,
                highlightCount: info.highlights,
                thoughtCount: info.thoughts,
                isWeChat: info.isWeChat
            )
        }.sorted { $0.highlightCount > $1.highlightCount }
    }

    private var filteredHighlights: [Highlight] {
        var list = viewModel.highlights

        // 1. Filter by Selected Book
        if let target = selectedBookTitle {
            list = list.filter { $0.bookTitle == target }
        }

        // 2. Filter by Source
        switch sourceFilter {
        case .all:
            break
        case .dreader:
            list = list.filter { !$0.isFromWeChatRead }
        case .wechat:
            list = list.filter { $0.isFromWeChatRead }
        }

        // 3. Search query
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            list = list.filter {
                $0.text.localizedCaseInsensitiveContains(q) ||
                ($0.note?.localizedCaseInsensitiveContains(q) ?? false) ||
                $0.bookTitle.localizedCaseInsensitiveContains(q) ||
                $0.chapterTitle.localizedCaseInsensitiveContains(q)
            }
        }

        return list
    }

    private var wechatNotesCount: Int {
        viewModel.highlights.filter { $0.isFromWeChatRead }.count
    }

    private var localNotesCount: Int {
        viewModel.highlights.filter { !$0.isFromWeChatRead }.count
    }

    /// Cards due for today's Mastery review (badge count)
    private var dueCount: Int {
        LibraryDatabase.shared.dueReviewCount()
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            headerBar

            Divider()
                .opacity(0.2)

            // Search & Filter Toolbar
            filterToolbar

            Divider()
                .opacity(0.15)

            // Main Two-Column Content: Left Bookshelf Sidebar, Right Highlights Stream
            HStack(spacing: 0) {
                // Left Books Directory
                leftBooksDirectory
                    .frame(width: 250)

                Divider()
                    .opacity(0.15)

                // Right Highlights Stream
                rightHighlightsStream
            }

            // Export Success Toast
            if showExportToast {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(exportToastMessage)
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.green.opacity(0.12))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(backgroundColor)
        .sheet(item: $quoteCardHighlight) { item in
            QuoteCardView(
                highlight: item,
                book: viewModel.books.first { $0.title == item.bookTitle },
                onClose: { quoteCardHighlight = nil }
            )
        }
        .sheet(isPresented: $showReviewSession) {
            ReviewSessionModalView(viewModel: viewModel) {
                showReviewSession = false
                highlightTick += 1
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            highlightTick += 1 // new day -> fresh due badge
        }
    }

    // MARK: - Header Bar
    private var headerBar: some View {
        HStack(spacing: 12) {
            // 返回书架：页面化后替代原 NSWindow 标题栏/xmark 关闭
            Button {
                onClose()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 11, weight: .semibold))
                    Text("书架")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Color.primary.opacity(0.85))
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(Color.primary.opacity(0.06))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("返回书架大厅 (⌘+B)")

            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: "#6B5B4A"), Color(hex: "#4A3E32")],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 32, height: 32)

                Image(systemName: "highlighter")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("个人知识库 · 划线与阅读思考回顾")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.primary)

                    // Counter Pill
                    HStack(spacing: 4) {
                        Text("共 \(viewModel.highlights.count) 条笔记")
                            .font(.system(size: 10.5, weight: .semibold))
                        if wechatNotesCount > 0 {
                            Text("· 微信读书 \(wechatNotesCount)")
                                .font(.system(size: 10))
                                .foregroundStyle(Color(hex: "#07C160"))
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(Color.primary.opacity(0.06))
                    .foregroundStyle(Color.primary.opacity(0.75))
                    .clipShape(Capsule())
                }

                Text("汇聚 DReader 本地深度批注与微信读书全量同步笔记，支持按书检索、思考编辑与闪卡导出")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // WeChat Sync Quick Trigger
            Button {
                viewModel.showWeChatSyncModal = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "quote.bubble.fill")
                        .font(.system(size: 11))
                    Text("微信读书同步")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(Color(hex: "#059648"))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color(hex: "#07C160").opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(hex: "#07C160").opacity(0.25), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .help("打开微信读书同步面板 (⌘+⇧+W)")

            // Daily Mastery Review Entry
            Button {
                showReviewSession = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 11))
                    Text("今日复习")
                    if dueCount > 0 {
                        Text(dueCount >= 99 ? "99+" : "\(dueCount)")
                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.white.opacity(0.85))
                            .foregroundStyle(Color.primary.opacity(0.75))
                            .clipShape(Capsule())
                    }
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.75))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .help("开始今日 Mastery 划线复习（间隔重现记忆）")

        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: - Filter Toolbar
    private var filterToolbar: some View {
        HStack(spacing: 12) {
            // Search Input
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                TextField("全文检索划线金句、个人思考、书名或章节...", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))

                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            // Source Filter
            Picker("", selection: $sourceFilter) {
                ForEach(HighlightSourceFilter.allCases) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 250)

            // Export Menu
            Menu {
                Button {
                    exportObsidian(filteredHighlights)
                } label: {
                    Label("导出为 Obsidian 双链笔记 (.md)", systemImage: "doc.text.fill")
                }

                Button {
                    exportAnki(filteredHighlights)
                } label: {
                    Label("导出为 Anki 知识记忆闪卡 (.txt)", systemImage: "rectangle.stack.badge.play.fill")
                }

                Divider()

                Button {
                    exportMarkdown(filteredHighlights)
                } label: {
                    Label("导出为标准 Markdown 文档 (.md)", systemImage: "square.and.arrow.up")
                }

                Button {
                    copyToClipboard(filteredHighlights)
                } label: {
                    Label("复制当前筛选笔记到剪贴板", systemImage: "doc.on.doc")
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 11))
                    Text("导出笔记 (\(filteredHighlights.count))")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.06))
                .foregroundStyle(Color.primary.opacity(0.75))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .menuStyle(.borderlessButton)
            .disabled(filteredHighlights.isEmpty)

            // Knowledge Asset Backup (SQLite transport format)
            Menu {
                Button {
                    exportJSONBackup()
                } label: {
                    Label("导出划线与书签备份 (.json)", systemImage: "externaldrive.badge.icloud")
                }

                Divider()

                Button {
                    importJSONBackup()
                } label: {
                    Label("从备份恢复 (合并导入)", systemImage: "arrow.down.doc")
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "externaldrive")
                        .font(.system(size: 11))
                    Text("备份")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.05))
                .foregroundStyle(.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.015))
    }

    // MARK: - JSON Backup Actions

    private func exportJSONBackup() {
        guard let data = try? LibraryDatabase.shared.exportBackup() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "DReader_知识备份_\(Date().formatted(date: .numeric, time: .omitted).replacingOccurrences(of: "/", with: "-")).json"
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url)
        }
    }

    private func importJSONBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        if let count = try? LibraryDatabase.shared.importBackup(data), count > 0 {
            viewModel.highlights = LibraryDatabase.shared.loadHighlights()
        }
    }

    // MARK: - Left Books Directory
    private var leftBooksDirectory: some View {
        VStack(alignment: .leading, spacing: 0) {
            // All Books Category Row
            Button {
                selectedBookTitle = nil
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "books.vertical.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(selectedBookTitle == nil ? Color.primary.opacity(0.75) : Color.secondary)

                    Text("全部图书划线")
                        .font(.system(size: 12.5, weight: selectedBookTitle == nil ? .bold : .medium))
                        .foregroundStyle(selectedBookTitle == nil ? Color.primary.opacity(0.85) : Color.primary)

                    Spacer()

                    Text("\(viewModel.highlights.count)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(selectedBookTitle == nil ? Color.primary.opacity(0.75) : Color.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selectedBookTitle == nil ? Color.primary.opacity(0.05) : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.top, 8)

            Divider()
                .opacity(0.2)
                .padding(.vertical, 6)

            // Books List
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(allBookGroups) { group in
                        let isSelected = (selectedBookTitle == group.title)
                        Button {
                            selectedBookTitle = group.title
                        } label: {
                            HStack(spacing: 8) {
                                // Book Icon with WeChat badge if applicable
                                ZStack(alignment: .bottomTrailing) {
                                    Image(systemName: "book.closed.fill")
                                        .font(.system(size: 13))
                                        .foregroundStyle(isSelected ? Color.primary.opacity(0.85) : Color.secondary.opacity(0.75))

                                    if group.isWeChat {
                                        Circle()
                                            .fill(Color(hex: "#07C160"))
                                            .frame(width: 5, height: 5)
                                            .offset(x: 2, y: 2)
                                    }
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ChineseScriptConverter.convert(group.title, mode: viewModel.settings.chineseScriptMode))
                                        .font(.system(size: 12, weight: isSelected ? .bold : .regular))
                                        .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.9))
                                        .lineLimit(1)

                                    if !group.author.isEmpty {
                                        Text(ChineseScriptConverter.convert(group.author, mode: viewModel.settings.chineseScriptMode))
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }

                                Spacer()

                                Text("\(group.highlightCount)")
                                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                    .foregroundStyle(isSelected ? Color.primary.opacity(0.8) : Color.secondary.opacity(0.7))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(isSelected ? Color.primary.opacity(0.07) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
        }
        .background(Color.primary.opacity(0.015))
    }

    // MARK: - Right Highlights Stream
    private var rightHighlightsStream: some View {
        ZStack {
            if filteredHighlights.isEmpty {
                emptyHighlightsView
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(filteredHighlights) { item in
                            globalHighlightCard(item)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty State View
    private var emptyHighlightsView: some View {
        VStack(spacing: 14) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(width: 68, height: 68)

                Image(systemName: "highlighter")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.primary.opacity(0.75))
            }

            Text(viewModel.highlights.isEmpty ? "知识库尚无划线或阅读思考" : "未找到匹配的划线内容")
                .font(.system(size: 14, weight: .bold))

            if viewModel.highlights.isEmpty {
                Text("在阅读器中选中文本即可高亮并记录思考；或者连接微信读书，一键导入你在微信读书中的所有划线与书评。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)

                Button {
                    viewModel.showWeChatSyncModal = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "quote.bubble.fill")
                        Text("前往微信读书同步笔记")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(Color(hex: "#07C160"))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            } else {
                Text("请尝试清除搜索关键词或切换来源标签")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Single Highlight Card
    private var localBooksMap: [String: EPUBBook] {
        var dict: [String: EPUBBook] = [:]
        for b in viewModel.books {
            dict[b.title] = b
        }
        return dict
    }

    private func globalHighlightCard(_ item: Highlight) -> some View {
        let matchingLocalBook = localBooksMap[item.bookTitle]

        return VStack(alignment: .leading, spacing: 8) {
            // Header: Book Title, Chapter, Source & Date
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(hex: item.colorHex))
                    .frame(width: 8, height: 8)

                Text("《\(ChineseScriptConverter.convert(item.bookTitle, mode: viewModel.settings.chineseScriptMode))》")
                    .font(.system(size: 12, weight: .bold, design: .serif))
                    .foregroundStyle(Color.primary)

                Text("·")
                    .foregroundStyle(.secondary)

                Text(ChineseScriptConverter.convert(item.chapterTitle, mode: viewModel.settings.chineseScriptMode))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if item.isFromWeChatRead {
                    HStack(spacing: 3) {
                        Image(systemName: "quote.bubble.fill")
                            .font(.system(size: 7.5))
                        Text("微信读书")
                            .font(.system(size: 8.5, weight: .semibold))
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Color(hex: "#07C160").opacity(0.14))
                    .foregroundStyle(Color(hex: "#059648"))
                    .clipShape(Capsule())
                } else {
                    Text("DReader")
                        .font(.system(size: 8.5, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.primary.opacity(0.06))
                        .foregroundStyle(Color.primary.opacity(0.75))
                        .clipShape(Capsule())
                }

                Spacer()

                Text(item.createdAt.formatted(date: .numeric, time: .shortened))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary.opacity(0.8))

                // Quote Card Generator
                Button {
                    quoteCardHighlight = item
                } label: {
                    Image(systemName: "photo.artframe")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.primary.opacity(0.75))
                }
                .buttonStyle(.plain)
                .help("制作精美金句书摘卡片")

                // Delete Button
                Button {
                    viewModel.deleteHighlight(item.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("删除此划线及思考")
            }

            // Quoted Highlight Text
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color(hex: item.colorHex))
                    .frame(width: 3.5)

                Text(ChineseScriptConverter.convert(item.text, mode: viewModel.settings.chineseScriptMode))
                    .font(.system(size: 12.5, design: .serif))
                    .foregroundStyle(Color.primary.opacity(0.92))
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(Color.primary.opacity(0.035))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            // User Thought / Note (WeChat Read or Local)
            if editingHighlightId == item.id {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("记录对这段话的想法与思索...", text: $editingThoughtText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5))

                    HStack {
                        Spacer()
                        Button("取消") {
                            editingHighlightId = nil
                        }
                        .font(.system(size: 10.5))
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)

                        Button("保存思考") {
                            viewModel.updateHighlight(id: item.id, note: editingThoughtText)
                            editingHighlightId = nil
                        }
                        .font(.system(size: 10.5, weight: .semibold))
                        .buttonStyle(.borderedProminent)
                        
                        .controlSize(.mini)
                    }
                }
                .padding(.top, 4)
            } else if let note = item.note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        HStack(spacing: 4) {
                            Text(item.isFromWeChatRead ? "💬 微信读书想法/点评" : "💭 我的个人想法")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(item.isFromWeChatRead ? Color(hex: "#059648") : Color.primary.opacity(0.7))
                        }

                        Spacer()

                        Button {
                            editingThoughtText = note
                            editingHighlightId = item.id
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("编辑我的想法")
                    }

                    Text(note)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.primary.opacity(0.85))
                        .lineSpacing(3)
                }
                .padding(9)
                .background(item.isFromWeChatRead ? Color(hex: "#07C160").opacity(0.06) : Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Button {
                    editingThoughtText = ""
                    editingHighlightId = item.id
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.bubble")
                            .font(.system(size: 10))
                        Text("添加个人阅读思考...")
                            .font(.system(size: 10.5))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.leading, 2)
            }

            // Bottom Jump Action if local book exists
            if let localBook = matchingLocalBook {
                HStack {
                    Spacer()
                    Button {
                        onClose()
                        viewModel.selectBookForReading(localBook)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            viewModel.jumpToHighlight(item)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "book.pages")
                                .font(.system(size: 10))
                            Text("在 DReader 中打开此书并定位高亮 ➔")
                                .font(.system(size: 10.5, weight: .medium))
                        }
                        .foregroundStyle(Color.primary.opacity(0.75))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 2)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }

    // MARK: - Export Helpers
    private func exportMarkdown(_ items: [Highlight]) {
        let md = buildMarkdown(items)
        saveToFile(content: md, defaultName: "DReader_Notes_\(Date().formatted(date: .numeric, time: .omitted)).md")
    }

    private func exportObsidian(_ items: [Highlight]) {
        var md = "# 📚 DReader 深度阅读笔记与思考汇总\n\n"
        md += "> 导出时间：\(Date().formatted(date: .complete, time: .shortened))\n\n"
        for item in items {
            md += "## [[《\(item.bookTitle)》]] · \(item.chapterTitle)\n"
            md += "- 来源：#\(item.isFromWeChatRead ? "微信读书" : "DReader")\n"
            md += "- 时间：\(item.createdAt.formatted(date: .numeric, time: .shortened))\n\n"
            md += "> \(item.text.replacingOccurrences(of: "\n", with: "\n> "))\n\n"
            if let note = item.note, !note.isEmpty {
                md += "**思考与随想**：\n\(note)\n\n"
            }
            md += "---\n\n"
        }
        saveToFile(content: md, defaultName: "Obsidian_Notes_\(Date().formatted(date: .numeric, time: .omitted)).md")
    }

    private func exportAnki(_ items: [Highlight]) {
        var tsv = "#separator:tab\n#html:true\n#tags column:3\n"
        for item in items {
            let front = "<p><b>《\(item.bookTitle)》</b>（\(item.chapterTitle)）</p><blockquote>\(item.text)</blockquote>"
            let back = item.note ?? "【原书高亮批注】"
            let tag = item.isFromWeChatRead ? "WeChatRead" : "DReader"
            tsv += "\(front)\t\(back)\t\(tag)\n"
        }
        saveToFile(content: tsv, defaultName: "Anki_Flashcards_\(Date().formatted(date: .numeric, time: .omitted)).txt")
    }

    private func copyToClipboard(_ items: [Highlight]) {
        let text = buildMarkdown(items)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        triggerToast("已成功复制 \(items.count) 条笔记到剪贴板！")
    }

    private func buildMarkdown(_ items: [Highlight]) -> String {
        var md = "# 📖 DReader 阅读笔记与思考合集\n\n"
        for item in items {
            md += "### 《\(item.bookTitle)》· \(item.chapterTitle)\n"
            md += "> \(item.text)\n\n"
            if let note = item.note, !note.isEmpty {
                md += "**【想法】**：\(note)\n\n"
            }
            md += "（标记时间：\(item.createdAt.formatted(date: .numeric, time: .shortened)) · 来源：\(item.displaySource)）\n\n---\n\n"
        }
        return md
    }

    private func saveToFile(content: String, defaultName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName
        panel.canCreateDirectories = true
        panel.begin { response in
            if response == .OK, let url = panel.url {
                try? content.write(to: url, atomically: true, encoding: .utf8)
                triggerToast("已成功导出至 \(url.lastPathComponent)")
            }
        }
    }

    private func triggerToast(_ msg: String) {
        exportToastMessage = msg
        withAnimation { showExportToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation { showExportToast = false }
        }
    }
}
