import SwiftUI
import UniformTypeIdentifiers

enum SidebarTab: String, CaseIterable, Identifiable {
    case toc = "目录"
    case highlights = "划线笔记"
    case bookmarks = "书签"
    case xray = "X-Ray"
    case library = "藏书"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .toc: return "list.bullet.indent"
        case .highlights: return "highlighter"
        case .bookmarks: return "bookmark.fill"
        case .xray: return "atom"
        case .library: return "books.vertical.fill"
        }
    }
}

struct SidebarView: View {
    @Binding var currentTab: SidebarTab
    let book: EPUBBook?
    let books: [EPUBBook]
    let highlights: [Highlight]
    var bookmarks: [Bookmark] = []
    let onSelectChapter: (Int) -> Void
    let onSelectBook: (EPUBBook) -> Void
    let onImportEPUB: () -> Void
    let onDeleteHighlight: (UUID) -> Void
    let onUpdateHighlight: ((UUID, String) -> Void)?
    var onMakeQuoteCard: ((Highlight) -> Void)? = nil
    var onDeleteBookmark: ((UUID) -> Void)? = nil
    var onSearchTerm: ((String) -> Void)? = nil
    var onAskAIAboutTerm: ((String) -> Void)? = nil
    let onDeleteBook: (UUID) -> Void

    @State private var tocSearchText: String = ""
    @State private var highlightSearchText: String = ""
    @State private var hoveredChapterIndex: Int? = nil
    @State private var editingHighlightId: UUID? = nil
    @State private var editingThoughtText: String = ""
    @State private var showExportSuccessToast: Bool = false

    private var currentBookHighlights: [Highlight] {
        highlights.filter { $0.bookId == book?.id || $0.bookTitle == book?.title }
    }

    private var currentBookBookmarks: [Bookmark] {
        bookmarks.filter { $0.bookId == book?.id || $0.bookTitle == book?.title }
    }

    private var filteredChapters: [(index: Int, chapter: EPUBChapter)] {
        guard let book = book else { return [] }
        let all: [(index: Int, chapter: EPUBChapter)] = book.chapters.enumerated().map { (index: $0.offset, chapter: $0.element) }
        let query = tocSearchText.trimmingCharacters(in: .whitespaces)
        if query.isEmpty { return all }
        return all.filter { $0.chapter.title.localizedCaseInsensitiveContains(query) }
    }

    private var filteredHighlights: [Highlight] {
        let query = highlightSearchText.trimmingCharacters(in: .whitespaces)
        if query.isEmpty { return currentBookHighlights }
        return currentBookHighlights.filter {
            $0.text.localizedCaseInsensitiveContains(query) ||
            ($0.note?.localizedCaseInsensitiveContains(query) ?? false) ||
            $0.chapterTitle.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Apple Books Style Translucent Segmented Bar
            sidebarHeaderTabSwitcher

            Divider()
                .opacity(0.2)

            // Main Content per active tab
            switch currentTab {
            case .toc:
                tocListView
            case .highlights:
                highlightsListView
            case .bookmarks:
                bookmarksListView
            case .xray:
                if let currentBook = book {
                    BookXRayView(
                        book: currentBook,
                        onJumpToChapter: onSelectChapter,
                        onSearchTerm: { term in
                            onSearchTerm?(term)
                        },
                        onAskAIAboutTerm: { term in
                            onAskAIAboutTerm?(term)
                        }
                    )
                } else {
                    VStack(spacing: 8) {
                        Spacer()
                        Image(systemName: "atom")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                        Text("请先打开一本书以透视 X-Ray")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            case .library:
                libraryListView
            }
        }
        .frame(minWidth: 240, idealWidth: 280, maxWidth: 340)
        .background(.ultraThinMaterial)
    }

    // MARK: - Header Tab Switcher (Apple Books Style)
    private var sidebarHeaderTabSwitcher: some View {
        HStack(spacing: 4) {
            ForEach(SidebarTab.allCases) { tab in
                let isSelected = (currentTab == tab)
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        currentTab = tab
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 11, weight: isSelected ? .semibold : .regular))

                        Text(tab.rawValue)
                            .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))

                        if tab == .highlights && !currentBookHighlights.isEmpty {
                            Text("\(currentBookHighlights.count)")
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(isSelected ? Color.purple : Color.primary.opacity(0.08))
                                .clipShape(Capsule())
                        }

                        if tab == .bookmarks && !currentBookBookmarks.isEmpty {
                            Text("\(currentBookBookmarks.count)")
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(isSelected ? Color.red : Color.primary.opacity(0.08))
                                .clipShape(Capsule())
                        }
                    }
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isSelected ? Color.primary.opacity(0.09) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - Table of Contents View
    private var tocListView: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                TextField("搜索目录章节...", text: $tocSearchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))

                if !tocSearchText.isEmpty {
                    Button {
                        tocSearchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()
                .opacity(0.2)

            if filteredChapters.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                    Text(tocSearchText.isEmpty ? "暂无章节目录" : "未找到匹配章节")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(filteredChapters, id: \.chapter.id) { item in
                                let isCurrent = (book?.currentChapterIndex == item.index)
                                let isHovered = (hoveredChapterIndex == item.index)

                                Button {
                                    onSelectChapter(item.index)
                                } label: {
                                    HStack(spacing: 8) {
                                        // Number indicator
                                        Text(String(format: "%02d", item.index + 1))
                                            .font(.system(size: 10.5, weight: isCurrent ? .bold : .medium, design: .monospaced))
                                            .foregroundStyle(isCurrent ? Color.purple : Color.secondary.opacity(0.75))
                                            .frame(width: 20, alignment: .leading)

                                        // Chapter Title
                                        Text(item.chapter.title)
                                            .font(.system(size: 12.5, weight: isCurrent ? .semibold : .regular))
                                            .foregroundStyle(isCurrent ? Color.purple : Color.primary.opacity(0.88))
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)

                                        Spacer()

                                        if isCurrent {
                                            Image(systemName: "bookmark.fill")
                                                .font(.system(size: 10))
                                                .foregroundStyle(.purple)
                                        }
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6.5)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(isCurrent ? Color.purple.opacity(0.12) : (isHovered ? Color.primary.opacity(0.05) : Color.clear))
                                    )
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .id(item.index)
                                .onHover { h in
                                    hoveredChapterIndex = h ? item.index : nil
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    }
                    .onAppear {
                        if let currentIdx = book?.currentChapterIndex {
                            proxy.scrollTo(currentIdx, anchor: .center)
                        }
                    }
                    .onChange(of: book?.currentChapterIndex) { _, newIdx in
                        if let idx = newIdx {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                proxy.scrollTo(idx, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Highlights & Thoughts View (Apple Books & WeChat Read Style)
    private var highlightsListView: some View {
        VStack(spacing: 0) {
            // Search & Stats Bar
            if !currentBookHighlights.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    TextField("搜索划线与想法...", text: $highlightSearchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))

                    if !highlightSearchText.isEmpty {
                        Button {
                            highlightSearchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

                Divider()
                    .opacity(0.2)
            }

            if filteredHighlights.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "highlighter")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary.opacity(0.8))
                    Text(currentBookHighlights.isEmpty ? "暂无划线与想法" : "未找到匹配笔记")
                        .font(.system(size: 13, weight: .medium))
                    Text(currentBookHighlights.isEmpty ? "在阅读页面选中文本，即可标记高亮并记录个人深度想法。" : "请尝试更改搜索关键词")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredHighlights) { item in
                            highlightCard(item)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }

                Divider()
                    .opacity(0.2)

                // Export Highlights Multi-Format Menu
                Menu {
                    Button {
                        exportHighlightsForObsidian(currentBookHighlights)
                    } label: {
                        Label("导出为 Obsidian 双链笔记 (.md)", systemImage: "doc.text.fill")
                    }

                    Button {
                        exportHighlightsForAnki(currentBookHighlights)
                    } label: {
                        Label("导出为 Anki 知识记忆闪卡 (.txt)", systemImage: "rectangle.stack.badge.play.fill")
                    }

                    Divider()

                    Button {
                        exportHighlightsAsMarkdown(currentBookHighlights)
                    } label: {
                        Label("导出为标准通用 Markdown (.md)", systemImage: "square.and.arrow.up")
                    }

                    Button {
                        copyAllHighlightsToClipboard(currentBookHighlights)
                    } label: {
                        Label("复制全部笔记内容到剪贴板", systemImage: "doc.on.doc")
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 11))
                        Text("导出知识库笔记 (Obsidian / Anki / MD)...")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6.5)
                    .background(Color.purple.opacity(0.1))
                    .foregroundStyle(.purple)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.purple.opacity(0.2), lineWidth: 0.5)
                    )
                }
                .menuStyle(.borderlessButton)
                .padding(10)
            }
        }
    }

    private func highlightCard(_ item: Highlight) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Chapter & Date Header
            HStack(spacing: 5) {
                Circle()
                    .fill(Color(hex: item.colorHex))
                    .frame(width: 7, height: 7)

                Text(item.chapterTitle)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()

                Text(item.createdAt.formatted(date: .numeric, time: .shortened))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary.opacity(0.8))

                Button {
                    onMakeQuoteCard?(item)
                } label: {
                    Image(systemName: "photo.artframe")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.purple)
                }
                .buttonStyle(.plain)
                .help("制作精美金句书摘卡片")

                Button {
                    onDeleteHighlight(item.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("删除此划线及想法")
            }

            // Quoted Text Card (click to jump)
            HStack(alignment: .top, spacing: 7) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color(hex: item.colorHex))
                    .frame(width: 3)

                Text(item.text)
                    .font(.system(size: 11.5, design: .serif))
                    .foregroundStyle(Color.primary.opacity(0.9))
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(7)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture {
                onSelectChapter(item.chapterIndex)
            }
            .help("点击跳转到该章节对应内容")

            // Thought Box (WeChat Read style)
            if editingHighlightId == item.id {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("记录对这段话的想法与思索...", text: $editingThoughtText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))

                    HStack {
                        Spacer()
                        Button("取消") {
                            editingHighlightId = nil
                        }
                        .font(.system(size: 10))
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)

                        Button("保存") {
                            onUpdateHighlight?(item.id, editingThoughtText)
                            editingHighlightId = nil
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                        .controlSize(.mini)
                    }
                }
                .padding(.top, 2)
            } else if let note = item.note, !note.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("💭 我的想法")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(Color.purple)

                        Spacer()

                        Button {
                            editingThoughtText = note
                            editingHighlightId = item.id
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.purple)
                        }
                        .buttonStyle(.plain)
                        .help("编辑想法")
                    }

                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.primary.opacity(0.88))
                        .lineSpacing(1.5)
                }
                .padding(7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.purple.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.purple.opacity(0.18), lineWidth: 0.5)
                )
            } else {
                Button {
                    editingThoughtText = ""
                    editingHighlightId = item.id
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 9))
                        Text("写想法...")
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(Color.secondary)
                }
                .buttonStyle(.plain)
                .padding(.leading, 2)
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }

    // MARK: - Bookmarks List View (折角书签)
    private var bookmarksListView: some View {
        VStack(spacing: 0) {
            if currentBookBookmarks.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "bookmark")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary.opacity(0.8))
                    Text("暂无折角书签")
                        .font(.system(size: 13, weight: .medium))
                    Text("阅读时按 ⌘+D 或点击右上角书签缎带，即可在此处快速标记重要页码。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(currentBookBookmarks) { bm in
                            bookmarkCard(bm)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private func bookmarkCard(_ bm: Bookmark) -> some View {
        HStack(alignment: .top, spacing: 9) {
            // Crimson Silk Ribbon Tag
            Rectangle()
                .fill(LinearGradient(colors: [Color(hex: "#C92A2A"), Color(hex: "#E03131")], startPoint: .top, endPoint: .bottom))
                .frame(width: 3.5, height: 36)
                .clipShape(Capsule())

            VStack(alignment: .leading, spacing: 3) {
                Text(bm.chapterTitle)
                    .font(.system(size: 12, weight: .semibold, design: .serif))
                    .foregroundStyle(Color.primary.opacity(0.9))
                    .lineLimit(1)

                Text("标记于 \(bm.createdAt.formatted(date: .numeric, time: .shortened))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                onDeleteBookmark?(bm.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("删除此书签")
        }
        .padding(9)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            onSelectChapter(bm.chapterIndex)
        }
        .help("点击跳转至该书签章节")
    }

    private func exportHighlightsAsMarkdown(_ items: [Highlight]) {
        guard let book = book else { return }

        var md = "# 《\(book.title)》读书笔记与思考\n\n"
        md += "> 作者：\(book.author)\n"
        md += "> 导出时间：\(Date().formatted(date: .numeric, time: .shortened))\n"
        md += "> 划线与想法记录：共 \(items.count) 条\n\n"
        md += "---\n\n"

        for (idx, h) in items.enumerated() {
            md += "### \(idx + 1). \(h.chapterTitle)\n\n"
            md += "> \(h.text)\n\n"
            if let note = h.note, !note.isEmpty {
                md += "**💡 我的思考与想法**：\n\(note)\n\n"
            }
            md += "*划线时间：\(h.createdAt.formatted(date: .numeric, time: .shortened))*\n\n"
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(md, forType: .string)

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        savePanel.nameFieldStringValue = "《\(book.title)》读书笔记.md"
        savePanel.title = "保存 Markdown 读书笔记"
        if savePanel.runModal() == .OK, let targetURL = savePanel.url {
            try? md.write(to: targetURL, atomically: true, encoding: .utf8)
        }
    }

    private func copyAllHighlightsToClipboard(_ items: [Highlight]) {
        guard let book = book else { return }
        var text = "《\(book.title)》读书笔记摘录（共 \(items.count) 条）：\n\n"
        for (idx, h) in items.enumerated() {
            text += "\(idx + 1). 【\(h.chapterTitle)】\n“\(h.text)”\n"
            if let note = h.note, !note.isEmpty {
                text += "💡 我的思考：\(note)\n"
            }
            text += "\n"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func exportHighlightsForObsidian(_ items: [Highlight]) {
        guard let book = book else { return }

        var md = """
        ---
        title: "\(book.title)"
        author: "\(book.author)"
        type: literature-notes
        tags: [reading, dreader, obsidian]
        total_notes: \(items.count)
        exported: "\(Date().formatted(date: .numeric, time: .shortened))"
        ---

        # 📚 《\(book.title)》读书笔记

        > **元数据**
        > - 原著作者：[[\(book.author)]]
        > - 划线想法：共 \(items.count) 条
        > - 知识库来源：DReader Native macOS AI E-Reader

        ---\n\n
        """

        for (idx, h) in items.enumerated() {
            md += "## [[\(h.chapterTitle)]] · 重点 \(idx + 1)\n\n"
            md += "> [!quote] 《\(book.title)》原文摘录\n"
            for line in h.text.components(separatedBy: "\n") {
                md += "> \(line)\n"
            }
            md += ">\n"
            md += "> — *章节：\(h.chapterTitle) · \(h.createdAt.formatted(date: .numeric, time: .shortened))*\n\n"

            if let note = h.note, !note.isEmpty {
                md += "> [!note] 💡 读者深度想法与思辨\n"
                for line in note.components(separatedBy: "\n") {
                    md += "> \(line)\n"
                }
                md += "\n"
            }
            md += "\n"
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(md, forType: .string)

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        savePanel.nameFieldStringValue = "《\(book.title)》Obsidian双链笔记.md"
        savePanel.title = "导出到 Obsidian 本地 Vault"
        if savePanel.runModal() == .OK, let targetURL = savePanel.url {
            try? md.write(to: targetURL, atomically: true, encoding: .utf8)
        }
    }

    private func exportHighlightsForAnki(_ items: [Highlight]) {
        guard let book = book else { return }

        var ankiTSV = "#separator:tab\n#html:true\n#tags:DReader 《\(book.title)》\n"
        for h in items {
            let front: String
            let back: String
            if let note = h.note, !note.isEmpty {
                front = "<b>【思考问题/思辨】</b><br>\(note.replacingOccurrences(of: "\t", with: " "))"
                back = "<b>《\(book.title)》· \(h.chapterTitle)</b><br><blockquote>\(h.text.replacingOccurrences(of: "\t", with: " "))</blockquote>"
            } else {
                front = "<b>【重点回忆】《\(book.title)》</b><br>\(h.chapterTitle)"
                back = "<blockquote>\(h.text.replacingOccurrences(of: "\t", with: " "))</blockquote>"
            }
            ankiTSV += "\(front.replacingOccurrences(of: "\n", with: "<br>"))\t\(back.replacingOccurrences(of: "\n", with: "<br>"))\n"
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ankiTSV, forType: .string)

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.tabSeparatedText, .plainText]
        savePanel.nameFieldStringValue = "《\(book.title)》Anki闪卡.txt"
        savePanel.title = "导出 Anki 知识记忆闪卡 (TSV)"
        if savePanel.runModal() == .OK, let targetURL = savePanel.url {
            try? ankiTSV.write(to: targetURL, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Library View (Apple Books Shelf View)
    private var libraryListView: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(books) { b in
                        let isCurrent = (book?.id == b.id)
                        Button {
                            onSelectBook(b)
                        } label: {
                            HStack(spacing: 10) {
                                // Mini Book Cover
                                ZStack {
                                    if let coverURL = b.coverImageURL, let nsImg = NSImage(contentsOf: coverURL) {
                                        Image(nsImage: nsImg)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 34, height: 46)
                                            .clipped()
                                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                            .shadow(color: .black.opacity(0.18), radius: 2, x: 0, y: 1)
                                    } else {
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .fill(LinearGradient(
                                                colors: [Color.purple.opacity(0.2), Color.purple.opacity(0.1)],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            ))
                                            .frame(width: 34, height: 46)
                                            .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)

                                        Image(systemName: "book.closed.fill")
                                            .font(.system(size: 15))
                                            .foregroundStyle(isCurrent ? .purple : .secondary)
                                    }
                                }

                                VStack(alignment: .leading, spacing: 2.5) {
                                    Text(b.title)
                                        .font(.system(size: 12.5, weight: isCurrent ? .semibold : .medium))
                                        .foregroundStyle(isCurrent ? Color.purple : Color.primary)
                                        .lineLimit(1)

                                    Text(b.author)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)

                                    Text("\(b.chapters.count) 章节 · 读至 \(Int(b.progress * 100))%")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary.opacity(0.8))
                                }

                                Spacer()

                                if isCurrent {
                                    Text("当前在读")
                                        .font(.system(size: 9.5, weight: .bold))
                                        .foregroundStyle(.purple)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.purple.opacity(0.12))
                                        .clipShape(Capsule())
                                }
                            }
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(isCurrent ? Color.purple.opacity(0.08) : Color.primary.opacity(0.03))
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("阅读此书") {
                                onSelectBook(b)
                            }
                            Divider()
                            Button("从书架移除", role: .destructive) {
                                onDeleteBook(b.id)
                            }
                        }
                    }
                }
                .padding(10)
            }

            Divider()
                .opacity(0.2)

            Button {
                onImportEPUB()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 12))
                    Text("导入本地 EPUB 电子书...")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(10)
        }
    }
}
