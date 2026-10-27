import SwiftUI

struct ReaderMainView: View {
    @Bindable var vm: ReaderViewModel
    @State private var showTypographyPopover: Bool = false
    @State private var isHoveringPrev: Bool = false
    @State private var isHoveringNext: Bool = false
    @State private var quoteCardHighlight: Highlight? = nil

    var body: some View {
        ZStack(alignment: .top) {
            Group {
                if vm.isViewingBookshelf {
                    RealisticBookshelfView(
                        books: vm.books,
                        onSelectBook: { book in
                            vm.selectBookForReading(book)
                        },
                        onImportEPUB: {
                            vm.showImportOpenPanel()
                        },
                        onOpenReadingInsights: {
                            vm.showReadingInsights = true
                        },
                        onOpenOnlineHub: {
                            vm.showOnlineBookHub = true
                        }
                    )
                    .transition(.opacity)
                } else {
                    readingWorkspaceView
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.22), value: vm.isViewingBookshelf)

            // Global Error Notification Toast
            if let errorMsg = vm.errorMessage {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.white)
                    Text(errorMsg)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white)
                    Spacer()
                    Button {
                        vm.errorMessage = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.red.opacity(0.92))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
                .padding(.horizontal, 24)
                .padding(.top, 14)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .sheet(item: $quoteCardHighlight) { highlight in
            QuoteCardView(
                highlight: highlight,
                book: vm.currentBook,
                onClose: {
                    quoteCardHighlight = nil
                }
            )
        }
        .sheet(isPresented: $vm.showReadingInsights) {
            ReadingInsightsModalView(stats: vm.readingStats) {
                vm.showReadingInsights = false
            }
        }
        .sheet(isPresented: $vm.showOnlineBookHub) {
            OnlineBookHubModalView(
                onBookDownloadedAndImport: { localURL in
                    Task { @MainActor in
                        await vm.openEPUB(url: localURL)
                    }
                },
                onClose: {
                    vm.showOnlineBookHub = false
                }
            )
        }
    }

    // MARK: - Reading Workspace View
    private var readingWorkspaceView: some View {
        HStack(spacing: 0) {
            // 1. Sidebar (TOC, Highlights, Books)
            if !vm.settings.isZenMode && vm.isSidebarVisible {
                SidebarView(
                    currentTab: $vm.sidebarTab,
                    book: vm.currentBook,
                    books: vm.books,
                    highlights: vm.highlights,
                    bookmarks: vm.bookmarks,
                    onSelectChapter: { index in
                        vm.jumpToChapter(index)
                    },
                    onSelectBook: { book in
                        vm.currentBook = book
                    },
                    onImportEPUB: {
                        vm.showImportOpenPanel()
                    },
                    onDeleteHighlight: { id in
                        vm.deleteHighlight(id)
                    },
                    onUpdateHighlight: { id, note in
                        vm.updateHighlight(id: id, note: note)
                    },
                    onMakeQuoteCard: { highlight in
                        quoteCardHighlight = highlight
                    },
                    onDeleteBookmark: { id in
                        vm.deleteBookmark(id: id)
                    },
                    onSearchTerm: { term in
                        withAnimation(.easeInOut(duration: 0.2)) {
                            vm.isSearchPresented = true
                        }
                        vm.performSearch(query: term)
                    },
                    onAskAIAboutTerm: { term in
                        vm.selectionManager.quoteForAI = "【X-Ray 核心透视】\(term)"
                        withAnimation(.easeInOut(duration: 0.2)) {
                            vm.isAIPanelVisible = true
                        }
                    },
                    onDeleteBook: { id in
                        vm.removeBook(id: id)
                    }
                )
                .transition(.move(edge: .leading))

                Divider()
            }

            // 2. Main Reader Area
            VStack(spacing: 0) {
                // Top Toolbar (hidden in Zen Mode)
                if !vm.settings.isZenMode {
                    readerTopBar
                }

                // Content View with Floating Controls Overlay
                ZStack(alignment: .bottom) {
                    ZStack(alignment: .topLeading) {
                        readerContentArea

                        // Floating Zen Mode Exit Pill
                        if vm.settings.isZenMode {
                            HStack {
                                Spacer()
                                Button {
                                    withAnimation(.easeInOut(duration: 0.25)) {
                                        vm.settings.isZenMode = false
                                    }
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                                            .font(.system(size: 10, weight: .bold))
                                        Text("退出禅意模式 (Esc)")
                                            .font(.system(size: 11, weight: .medium))
                                    }
                                    .foregroundStyle(vm.settings.theme.swiftUIText.opacity(0.8))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(.ultraThinMaterial)
                                    .clipShape(Capsule())
                                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                                }
                                .buttonStyle(.plain)
                                .padding(14)
                            }
                            .frame(maxWidth: .infinity, alignment: .topTrailing)
                        }

                        // Floating Toolbars & Cards Geometry-Constrained Overlay
                        GeometryReader { geo in
                            let areaW = geo.size.width
                            let areaH = geo.size.height

                            // 1. Floating Selection Toolbar
                            if let selection = vm.selectionManager.activeSelection {
                                let barW: CGFloat = 340
                                let posX = min(max(selection.x, barW / 2 + 12), max(barW / 2 + 12, areaW - barW / 2 - 12))
                                let posY = max(selection.y - 32, 28)

                                SelectionFloatingToolbar(
                                    selection: selection,
                                    onAskAI: { text in
                                        vm.selectionManager.quoteForAI = text
                                        vm.isAIPanelVisible = true
                                        let prompt = "请结合当前书本语境，对选中的这段内容进行深度导读与提炼，剖析其微言大义、作者意图与核心思想："
                                        NotificationCenter.default.post(
                                            name: NSNotification.Name("DReaderTriggerAIPrompt"),
                                            object: nil,
                                            userInfo: ["prompt": prompt, "quote": text]
                                        )
                                    },
                                    onQuickPrompt: { type, text in
                                        vm.selectionManager.quoteForAI = text
                                        vm.isAIPanelVisible = true
                                        let prompt: String
                                        switch type {
                                        case "explain":
                                            prompt = "请深入解析以下选中文本的思想内涵与深层寓意："
                                        case "summarize":
                                            prompt = "请提炼以下选中文本的核心论点与3个关键要点："
                                        case "translate":
                                            prompt = "请对以下选中文本进行原汁原味的文学精译并解析关键词："
                                        default:
                                            prompt = "请对选中文本进行深度剖析："
                                        }
                                        NotificationCenter.default.post(
                                            name: NSNotification.Name("DReaderTriggerAIPrompt"),
                                            object: nil,
                                            userInfo: ["prompt": prompt, "quote": text]
                                        )
                                    },
                                    onHighlight: { colorHex in
                                        vm.applyHighlight(colorHex: colorHex)
                                    },
                                    onWriteThought: {
                                        if let h = vm.applyHighlight(colorHex: vm.lastChosenHighlightColor) {
                                            vm.selectionManager.activeHighlightCard = HighlightCardInfo(
                                                highlightId: h.id,
                                                x: selection.x,
                                                y: selection.y,
                                                bottomY: selection.bottomY
                                            )
                                        }
                                    },
                                    onMakeQuoteCard: {
                                        if let h = vm.applyHighlight(colorHex: vm.lastChosenHighlightColor) {
                                            quoteCardHighlight = h
                                        } else if let chapter = vm.currentBook?.currentChapter {
                                            let temp = Highlight(
                                                bookId: vm.currentBook?.id ?? UUID(),
                                                bookTitle: vm.currentBook?.title ?? "",
                                                chapterIndex: vm.currentBook?.currentChapterIndex ?? 0,
                                                chapterTitle: chapter.title,
                                                text: selection.text,
                                                colorHex: vm.lastChosenHighlightColor,
                                                createdAt: Date()
                                            )
                                            quoteCardHighlight = temp
                                        }
                                    },
                                    onLookUp: { text in
                                        vm.speakText(text)
                                        vm.selectionManager.quoteForAI = text
                                        vm.isAIPanelVisible = true
                                        let prompt = "请为词汇/短语「\(text)」提供权威深度词典解析：包含【标准发音/拼音】、【词性与基本释义】、【在本书语境中的微言大义与深层寓意】及【近义词与典故词源】。"
                                        NotificationCenter.default.post(
                                            name: NSNotification.Name("DReaderTriggerAIPrompt"),
                                            object: nil,
                                            userInfo: ["prompt": prompt, "quote": text]
                                        )
                                        vm.selectionManager.clear()
                                    },
                                    onDismiss: {
                                        vm.selectionManager.clear()
                                    }
                                )
                                .position(x: posX, y: posY)
                                .transition(.scale(scale: 0.95).combined(with: .opacity))
                            }

                            // 2. Floating Highlight & Thought Interaction Card
                            if let cardInfo = vm.selectionManager.activeHighlightCard,
                               let highlight = vm.highlights.first(where: { $0.id == cardInfo.highlightId }) {
                                let cardW: CGFloat = 280
                                let cardH: CGFloat = 175
                                let posX = min(max(cardInfo.x, cardW / 2 + 12), max(cardW / 2 + 12, areaW - cardW / 2 - 12))

                                // Smart vertical placement: above if near bottom, else below
                                let posY: CGFloat = (cardInfo.bottomY + cardH + 20 < areaH)
                                    ? (cardInfo.bottomY + cardH / 2 + 8)
                                    : max(cardH / 2 + 8, cardInfo.y - cardH / 2 - 8)

                                HighlightDetailCard(
                                    highlight: highlight,
                                    onUpdateColor: { newColor in
                                        vm.updateHighlight(id: highlight.id, colorHex: newColor)
                                    },
                                    onSaveThought: { newThought in
                                        vm.updateHighlight(id: highlight.id, note: newThought)
                                    },
                                    onDelete: {
                                        vm.deleteHighlight(highlight.id)
                                    },
                                    onAskAI: { quote in
                                        vm.selectionManager.activeHighlightCard = nil
                                        vm.selectionManager.quoteForAI = quote
                                        vm.isAIPanelVisible = true
                                        let prompt = "请结合当前书本语境，对这段划线内容及思考展开深度解读："
                                        NotificationCenter.default.post(
                                            name: NSNotification.Name("DReaderTriggerAIPrompt"),
                                            object: nil,
                                            userInfo: ["prompt": prompt, "quote": quote]
                                        )
                                    },
                                    onMakeQuoteCard: {
                                        vm.selectionManager.activeHighlightCard = nil
                                        quoteCardHighlight = highlight
                                    },
                                    onDismiss: {
                                        vm.selectionManager.activeHighlightCard = nil
                                    }
                                )
                                .position(x: posX, y: posY)
                                .transition(.scale(scale: 0.95).combined(with: .opacity))
                                .zIndex(100)
                            }
                        }
                    }

                    // Bottom Floating Scrubber Pill (Apple Books Translucent Glass Pill)
                    if !vm.settings.isZenMode {
                        floatingReaderBottomBar
                            .padding(.bottom, 16)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(vm.settings.theme.swiftUIBackground)

            // 3. Trailing AI Panel (hidden in Zen Mode)
            if !vm.settings.isZenMode && vm.isAIPanelVisible {
                Divider()

                AIChatPanel(
                    book: vm.currentBook,
                    currentChapter: vm.currentBook?.currentChapter,
                    allBooks: vm.books,
                    activeQuote: $vm.selectionManager.quoteForAI,
                    agentService: vm.agentService,
                    onClose: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            vm.isAIPanelVisible = false
                        }
                    }
                )
                .transition(.move(edge: .trailing))
            }
        }
    }

    // MARK: - Reader Top Bar (Apple Books Style Translucent Bar)
    private var readerTopBar: some View {
        HStack(spacing: 12) {
            // Return to Bookshelf Button (Frosted Glass Capsule)
            Button {
                vm.returnToBookshelf()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 11, weight: .semibold))
                    Image(systemName: "books.vertical.fill")
                        .font(.system(size: 11))
                    Text("书架")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Color.primary.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .help("返回书架大厅 (Esc / ⌘+B)")

            // Sidebar Toggle Glass Pill
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    vm.isSidebarVisible.toggle()
                }
            } label: {
                Image(systemName: "sidebar.leading")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(vm.isSidebarVisible ? Color.purple : Color.primary.opacity(0.75))
                    .frame(width: 28, height: 28)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(vm.isSidebarVisible ? Color.purple.opacity(0.4) : Color.white.opacity(0.2), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .help("展开/折叠目录与书签")

            // Import Button
            Button {
                vm.showImportOpenPanel()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.75))
                    .frame(width: 28, height: 28)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .help("导入新 EPUB 电子书")

            // Online Book Hub Button (Z-Lib & Open Library)
            Button {
                vm.showOnlineBookHub = true
            } label: {
                Image(systemName: "globe.americas.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.purple)
                    .frame(width: 28, height: 28)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(Color.purple.opacity(0.35), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .help("探索在线数字书库 (⌘ + L)")

            Spacer()

            // Book & Chapter Center Floating Header
            VStack(spacing: 1.5) {
                Text(vm.currentBook?.title ?? "DReader 阅读器")
                    .font(.system(size: 13, weight: .semibold, design: .serif))
                    .lineLimit(1)
                    .foregroundStyle(vm.settings.theme.swiftUIText.opacity(0.95))

                if let currentChapter = vm.currentBook?.currentChapter {
                    Text(currentChapter.title)
                        .font(.system(size: 10.5, weight: .regular))
                        .foregroundStyle(Color(hex: vm.settings.theme.secondaryTextColorHex).opacity(0.85))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 3)

            Spacer()

            // In-Book Search Button (Apple Books Magnifying Glass ⌘+F)
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    vm.isSearchPresented.toggle()
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(vm.isSearchPresented ? Color.purple : Color.primary.opacity(0.8))
                    .frame(width: 28, height: 28)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(vm.isSearchPresented ? Color.purple.opacity(0.4) : Color.white.opacity(0.2), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut("f", modifiers: .command)
            .help("全书全文检索 (⌘ + F)")

            // Bookmark Toggle Button (Apple Books Bookmark Icon ⌘+D)
            Button {
                vm.toggleCurrentChapterBookmark()
            } label: {
                Image(systemName: vm.isCurrentChapterBookmarked() ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(vm.isCurrentChapterBookmarked() ? Color.red : Color.primary.opacity(0.8))
                    .frame(width: 28, height: 28)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(vm.isCurrentChapterBookmarked() ? Color.red.opacity(0.4) : Color.white.opacity(0.2), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut("d", modifiers: .command)
            .help(vm.isCurrentChapterBookmarked() ? "移除当前书签 (⌘ + D)" : "添加折角书签 (⌘ + D)")

            // Typography Setting Popover Button (Apple Books "Aa" Icon)
            Button {
                showTypographyPopover.toggle()
            } label: {
                Image(systemName: "textformat.size")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(showTypographyPopover ? Color.purple : Color.primary.opacity(0.8))
                    .frame(width: 28, height: 28)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(showTypographyPopover ? Color.purple.opacity(0.4) : Color.white.opacity(0.2), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showTypographyPopover, arrowEdge: .bottom) {
                ReaderTypographySettingsPopover(settings: vm.settings)
            }
            .help("排版设置与主题风格")

            // Reading Insights Pill (Apple Fitness Streak Icon)
            Button {
                vm.showReadingInsights = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Text("\(vm.readingStats.currentStreakDays)天")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.primary.opacity(0.85))
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .overlay(
                    Capsule().stroke(Color.orange.opacity(0.3), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .help("阅读统计与成就打卡")

            // Zen Mode Quick Toggle Button
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    vm.settings.isZenMode.toggle()
                }
            } label: {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.75))
                    .frame(width: 28, height: 28)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .help("全屏禅意沉浸模式 (⌘ + Enter)")

            // AI Panel Toggle (Luminescent Glass Capsule)
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    vm.isAIPanelVisible.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                    Text("AI 伴读")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .foregroundStyle(vm.isAIPanelVisible ? Color.white : Color.purple)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(
                    vm.isAIPanelVisible
                        ? AnyShapeStyle(LinearGradient(colors: [Color.purple, Color.indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                        : AnyShapeStyle(.ultraThinMaterial)
                )
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(vm.isAIPanelVisible ? Color.white.opacity(0.3) : Color.purple.opacity(0.3), lineWidth: 0.5)
                )
                .shadow(color: vm.isAIPanelVisible ? Color.purple.opacity(0.3) : Color.clear, radius: 6, y: 2)
            }
            .buttonStyle(.plain)
            .help("展开/折叠 AI 伴读面板 (⌘ + Shift + K)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial)
        .overlay(
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 0.5),
            alignment: .bottom
        )
    }

    // MARK: - Reader Content Area
    private var readerContentArea: some View {
        Group {
            if vm.isLoadingBook {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在解析 EPUB 电子书...")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let book = vm.currentBook, let chapter = book.currentChapter {
                ZStack {
                    // Core WebKit View
                    EPUBWebView(
                        chapterURL: chapter.fileURL,
                        opfDirectory: book.opfDirectory,
                        unzippedDirectory: book.unzippedDirectory,
                        highlights: vm.currentChapterHighlights(),
                        bookTitle: book.title,
                        chapterTitle: chapter.title,
                        chapterIndex: book.currentChapterIndex,
                        hasNextChapter: vm.hasNextChapter,
                        nextChapterTitle: vm.nextChapterTitle,
                        settings: vm.settings,
                        selectionManager: vm.selectionManager,
                        onHighlightApplied: { color, id in },
                        onNextChapter: { vm.nextChapter() },
                        onPrevChapter: { vm.prevChapter() },
                        onSocraticAI: { question in
                            vm.selectionManager.quoteForAI = "【苏格拉底之问】\(question)"
                            withAnimation(.easeInOut(duration: 0.2)) {
                                vm.isAIPanelVisible = true
                            }
                        },
                        onSocraticThought: { question in
                            vm.applyHighlight(colorHex: "#FFE066", note: "【针对苏格拉底之问的思考】：\n\(question)")
                        },
                        onScrollProgress: { pct in vm.chapterScrollProgress = pct },
                        registerScrollAction: { action in vm.scrollPageAction = action },
                        registerHighlightAction: { action in vm.applyHighlightAction = action },
                        registerUpdateColorAction: { action in vm.updateHighlightColorAction = action },
                        registerUpdateThoughtAction: { action in vm.updateHighlightThoughtAction = action },
                        registerRemoveHighlightAction: { action in vm.removeHighlightAction = action },
                        registerScrollToSearchMatchAction: { action in vm.scrollToSearchMatchAction = action },
                        getCachedHTML: { vm.getCachedHTML(for: $0) },
                        cacheHTML: { vm.cacheHTML($0, for: $1) }
                    )

                    // Top-Right Physical Dog-Ear Bookmark Ribbon
                    VStack {
                        HStack {
                            Spacer()
                            DogEarBookmarkRibbonView(
                                isBookmarked: vm.isCurrentChapterBookmarked(),
                                onToggle: {
                                    vm.toggleCurrentChapterBookmark()
                                }
                            )
                            .padding(.trailing, 26)
                        }
                        Spacer()
                    }

                    // Floating In-Book Full-Text Search Panel (⌘+F)
                    if vm.isSearchPresented {
                        VStack {
                            HStack {
                                Spacer()
                                InBookSearchPanel(vm: vm)
                                    .padding(.top, 10)
                                    .padding(.trailing, 22)
                            }
                            Spacer()
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(200)
                    }

                    // Floating Edge Page-Turning Arrows (Left & Right)
                    HStack {
                        // Left Page Turn Button
                        Button {
                            vm.scrollPage(direction: -1)
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(isHoveringPrev ? Color.primary : Color.secondary)
                                .frame(width: 32, height: 64)
                                .background(.ultraThinMaterial)
                                .clipShape(Capsule())
                                .shadow(color: .black.opacity(isHoveringPrev ? 0.16 : 0.04), radius: 6, x: 2, y: 2)
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 8)
                        .opacity(isHoveringPrev ? 0.95 : 0.22)
                        .onHover { h in
                            withAnimation(.easeInOut(duration: 0.15)) {
                                isHoveringPrev = h
                            }
                        }
                        .help("上一页 / 上一章 (PageUp / Shift+Space)")

                        Spacer()

                        // Right Page Turn Button
                        Button {
                            vm.scrollPage(direction: 1)
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(isHoveringNext ? Color.primary : Color.secondary)
                                .frame(width: 32, height: 64)
                                .background(.ultraThinMaterial)
                                .clipShape(Capsule())
                                .shadow(color: .black.opacity(isHoveringNext ? 0.16 : 0.04), radius: 6, x: -2, y: 2)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 8)
                        .opacity(isHoveringNext ? 0.95 : 0.22)
                        .onHover { h in
                            withAnimation(.easeInOut(duration: 0.15)) {
                                isHoveringNext = h
                            }
                        }
                        .help("下一页 / 下一章 (PageDown / Space)")
                    }
                    .padding(.vertical, 30)
                }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "book.pages")
                        .font(.system(size: 48))
                        .foregroundStyle(.purple.gradient)

                    Text("欢迎使用 DReader 现代阅读器")
                        .font(.system(size: 18, weight: .semibold))

                    Text("支持优雅排版、选中划线即刻调用本地 AI Agent 进行深度阅读与思辨。")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)

                    Button("导入 EPUB 电子书") {
                        vm.showImportOpenPanel()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Floating Bottom Scrubber (Apple Books Translucent Glass Pill)
    private var floatingReaderBottomBar: some View {
        HStack(spacing: 10) {
            // Chapter Navigator: Previous Chapter Button
            Button {
                vm.prevChapter()
            } label: {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(vm.hasPrevChapter ? Color.primary.opacity(0.85) : Color.secondary.opacity(0.35))
                    .frame(width: 24, height: 24)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!vm.hasPrevChapter)
            .help("上一章 (⌘ + [)")

            // Page Scroll Up Button
            Button {
                vm.scrollPage(direction: -1)
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .background(Color.primary.opacity(0.03))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("向上翻页 (PageUp / Shift+Space)")

            // Chapter Dropdown Menu & Scrubber
            if let book = vm.currentBook {
                HStack(spacing: 8) {
                    Menu {
                        ForEach(book.chapters.indices, id: \.self) { idx in
                            Button {
                                vm.jumpToChapter(idx)
                            } label: {
                                HStack {
                                    Text("第 \(idx + 1) 章：\(book.chapters[idx].title)")
                                    if idx == book.currentChapterIndex {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("第 \(book.currentChapterIndex + 1) / \(book.chapters.count) 章")
                                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.primary.opacity(0.88))
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(Capsule())
                    }
                    .menuStyle(.borderlessButton)

                    // Chapter Slider
                    if book.chapters.count > 1 {
                        Slider(
                            value: Binding(
                                get: { Double(book.currentChapterIndex) },
                                set: { vm.jumpToChapter(Int($0)) }
                            ),
                            in: 0...Double(book.chapters.count - 1),
                            step: 1
                        )
                        .frame(width: 86)
                        .tint(Color.purple)
                    }

                    // Overall Book Progress Percentage
                    Text("\(Int(vm.overallBookProgress * 100))%")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Divider()
                        .frame(height: 12)
                        .opacity(0.2)

                    // Apple Books Reading Time Remaining
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Text("本章剩约\(vm.currentChapterRemainingMinutes())分钟 · \(vm.bookRemainingTimeFormatted())")
                            .font(.system(size: 10.5, weight: .regular))
                            .foregroundStyle(Color.secondary.opacity(0.9))
                    }
                }
            }

            // Page Scroll Down Button
            Button {
                vm.scrollPage(direction: 1)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .background(Color.primary.opacity(0.03))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("向下翻页 (PageDown / Space)")

            // Chapter Navigator: Next Chapter Button
            Button {
                vm.nextChapter()
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(vm.hasNextChapter ? Color.primary.opacity(0.85) : Color.secondary.opacity(0.35))
                    .frame(width: 24, height: 24)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!vm.hasNextChapter)
            .help("下一章 (⌘ + ])")

            Divider()
                .frame(height: 14)
                .opacity(0.2)

            // Local Agent Badge Button
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    vm.isAIPanelVisible.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                        .shadow(color: .green.opacity(0.6), radius: 3)
                    Text("\(vm.agentService.currentPreset.name)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.85))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(Color.primary.opacity(0.05))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("当前伴读 Agent：\(vm.agentService.currentPreset.name)，点击展开讨论面板")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 4)
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
                )
        )
    }
}
