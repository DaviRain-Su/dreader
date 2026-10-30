import SwiftUI

struct RealisticBookshelfView: View {
    let books: [EPUBBook]
    let onSelectBook: (EPUBBook) -> Void
    let onImportEPUB: () -> Void
    var onOpenReadingInsights: (() -> Void)? = nil
    var onOpenOnlineHub: (() -> Void)? = nil
    var onOpenWeChatSync: (() -> Void)? = nil
    var onOpenGlobalNotebooks: (() -> Void)? = nil
    var onDeleteBook: ((UUID) -> Void)? = nil
    var onResetProgress: ((UUID) -> Void)? = nil
    var onOpenXRay: ((EPUBBook) -> Void)? = nil
    var onAddClassic: ((ChineseClassicsRegistry.ClassicBook) -> Void)? = nil
    var onStartReview: (() -> Void)? = nil
    var chineseScriptMode: ChineseScriptMode = .original

    private enum ShelfDisplayMode {
        case classic, gallery
    }

    @State private var searchText: String = ""
    @State private var displayMode: ShelfDisplayMode = .classic
    @State private var dueReviewCount: Int = 0

    private func refreshDueCount() {
        dueReviewCount = LibraryDatabase.shared.dueReviewCount()
    }

    private var filteredBooks: [EPUBBook] {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return books
        }
        return books.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.author.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var recommendedClassics: [ChineseClassicsRegistry.ClassicBook] {
        let existingTitles = Set(books.map { $0.title })
        return ChineseClassicsRegistry.shared.allClassics.filter { classic in
            !existingTitles.contains(where: { $0.contains(classic.title) || classic.title.contains($0) })
        }
    }

    // Chunk books into shelves of 4
    private var shelfRows: [[EPUBBook]] {
        stride(from: 0, to: filteredBooks.count, by: 4).map {
            Array(filteredBooks[$0..<min($0 + 4, filteredBooks.count)])
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if displayMode == .classic {
                bookshelfTopBar
            } else {
                galleryTopBar
            }

            Divider()
                .opacity(0.2)

            if displayMode == .gallery {
                BookshelfGalleryView(
                    books: filteredBooks,
                    onSelectBook: onSelectBook,
                    onImportEPUB: onImportEPUB,
                    onOpenXRay: onOpenXRay,
                    onResetProgress: onResetProgress,
                    onDeleteBook: onDeleteBook,
                    emptyMessage: searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "书库暂时还没有藏书" : "没有匹配的书籍",
                    chineseScriptMode: chineseScriptMode
                )
            } else {
            // Scrollable Wooden Bookshelf Racks
            ScrollView {
                LazyVStack(spacing: 36) {
                    // Ceiling Warm Ambient Light
                    Rectangle()
                        .fill(Color.clear)
                        .frame(height: 12)

                    if shelfRows.isEmpty {
                        WarmEmptyStudyView(
                            onImportEPUB: onImportEPUB,
                            onOpenOnlineHub: onOpenOnlineHub,
                            onOpenWeChatSync: onOpenWeChatSync,
                            onOpenGlobalNotebooks: onOpenGlobalNotebooks,
                            recommendedClassics: recommendedClassics,
                            onAddClassic: { classic in
                                onAddClassic?(classic)
                            }
                        )
                    } else {
                        ForEach(Array(shelfRows.enumerated()), id: \.offset) { index, rowBooks in
                            SingleShelfRowView(
                                books: rowBooks,
                                isLastRow: index == shelfRows.count - 1,
                                onSelectBook: onSelectBook,
                                onImportEPUB: onImportEPUB,
                                onOpenXRay: onOpenXRay,
                                onResetProgress: onResetProgress,
                                onDeleteBook: onDeleteBook,
                                chineseScriptMode: chineseScriptMode
                            )
                        }

                        // Curated Heritage Masterpieces Shelf (renders when personal shelf is < 6 or as featured shelf)
                        if !recommendedClassics.isEmpty && books.count < 6 {
                            CuratedClassicsShelfView(
                                classics: recommendedClassics,
                                onAddClassic: { classic in
                                    onAddClassic?(classic)
                                }
                            )
                        }
                    }

                    Spacer(minLength: 48)
                }
                .padding(.horizontal, 32)
                .padding(.top, 20)
            }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            refreshDueCount()
        }
        .background {
            if displayMode == .gallery {
                Color(hex: "#EDEBE6").ignoresSafeArea()
            } else {
                ZStack {
                    LinearGradient(
                        colors: [Color(hex: "#1F1511"), Color(hex: "#180F0C"), Color(hex: "#120B08")],
                        startPoint: .top, endPoint: .bottom
                    )
                    RadialGradient(
                        colors: [Color(hex: "#FFEDD5").opacity(0.08), Color.clear],
                        center: .top, startRadius: 40, endRadius: 750
                    )
                }
                .ignoresSafeArea()
            }
        }
    }

    // MARK: - Top Bar
    private var bookshelfTopBar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color(hex: "#E5C07B"))

                VStack(alignment: .leading, spacing: 1) {
                    Text("DReader")
                        .font(.system(size: 15, weight: .bold, design: .serif))
                        .foregroundStyle(Color(hex: "#F5E6C8"))
                    Text("私人典藏书架 · \(books.count) 卷藏书")
                        .font(.system(size: 10, design: .serif))
                        .foregroundStyle(Color(hex: "#CBB393").opacity(0.8))
                }
            }

            Button {
                displayMode = .gallery
            } label: {
                Label("长廊预览", systemImage: "rectangle.split.2x1")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(hex: "#E5C07B"))
            }
            .buttonStyle(.plain)
            .help("以藏书长廊预览真实书籍；经典木架保持默认")

            Spacer()

            // Search Bar
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(hex: "#CBB393").opacity(0.6))

                TextField("在书架中搜索书名或作者...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: "#F5E6C8"))

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(hex: "#CBB393").opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(width: 240)
            .background(Color.black.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(hex: "#E5C07B").opacity(0.25), lineWidth: 0.5)
            )

            // 右侧功能组：统一的暗玻璃「雕花铜牌」风格——无彩 chrome，
            // 唯一的彩色留给「今日复习」的到期角标（唯一需要用户行动的信号）
            ShelfTopBarButton(icon: "flame.fill", label: streakLabel, ring: streakRing) {
                onOpenReadingInsights?()
            }
            .help("查看阅读统计与成就殿堂")

            ShelfTopBarButton(icon: "brain.head.profile.fill", label: "今日复习", badgeCount: dueReviewCount > 0 ? dueReviewCount : nil) {
                onStartReview?()
            }
            .help("开始今日划线 Mastery 记忆复习 (⌘+⇧+R)")

            ShelfTopBarButton(icon: "globe.americas.fill", label: "在线书库") {
                onOpenOnlineHub?()
            }
            .help("探索 Open Library、古腾堡、Z-Library 与 OPDS 自建书馆 (⌘ + L)")

            ShelfTopBarButton(icon: "quote.bubble.fill", label: "微信读书") {
                onOpenWeChatSync?()
            }
            .help("同步微信读书划线与想法 (⌘ + ⇧ + W)")

            ShelfTopBarButton(icon: "highlighter", label: "划线笔记") {
                onOpenGlobalNotebooks?()
            }
            .help("查看全书库划线、想法与微信读书笔记 (⌘ + ⇧ + N)")

            // 导入是书架上唯一的「实心黄铜」主行动——其余全为暗玻璃
            Button(action: onImportEPUB) {
                HStack(spacing: 5) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 11))
                    Text("导入书籍")
                        .font(.system(size: 12, weight: .semibold, design: .serif))
                }
                .foregroundStyle(Color(hex: "#241708"))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    LinearGradient(
                        colors: [Color(hex: "#E8C883"), Color(hex: "#C9A24B")],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
            }
            .buttonStyle(.plain)
            .help("导入本地 EPUB 文件 (⌘ + O)")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Color.black.opacity(0.25))
    }

    private var galleryTopBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color(hex: "#1F3FB0"))
                VStack(alignment: .leading, spacing: 1) {
                    Text("DReader")
                        .font(.system(size: 15, weight: .bold, design: .serif))
                        .foregroundStyle(Color(hex: "#141414"))
                    Text("藏书长廊 · \(books.count) 卷藏书")
                        .font(.system(size: 10, design: .serif))
                        .foregroundStyle(Color(hex: "#6D6A63"))
                }
            }

            Button("经典木架") {
                displayMode = .classic
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(hex: "#6D6A63"))
                TextField("在书架中搜索书名或作者...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: "#141414"))
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color(hex: "#6D6A63"))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除搜索")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(width: 240)
            .background(Color.white.opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(hex: "#6D6A63").opacity(0.25), lineWidth: 0.5)
            )

            Menu {
                if let onOpenReadingInsights {
                    Button("阅读统计", action: onOpenReadingInsights)
                }
                if let onStartReview {
                    Button(dueReviewCount > 0 ? "今日复习（\(dueReviewCount) 待复习）" : "今日复习",
                           action: onStartReview)
                }
                if let onOpenOnlineHub {
                    Button("在线书库", action: onOpenOnlineHub)
                }
                if let onOpenWeChatSync {
                    Button("微信读书", action: onOpenWeChatSync)
                }
                if let onOpenGlobalNotebooks {
                    Button("划线笔记", action: onOpenGlobalNotebooks)
                }
            } label: {
                Label("书库工具", systemImage: "ellipsis.circle")
                    .font(.system(size: 11, weight: .medium))
            }
            .menuStyle(.borderlessButton)

            Button(action: onImportEPUB) {
                Label("导入书籍", systemImage: "plus.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(hex: "#1F3FB0"))
            .help("导入本地 EPUB 文件 (⌘ + O)")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(Color(hex: "#EDEBE6"))
    }

    private var streakLabel: String {
        "连续 \(ReadingStatsManager.shared.stats.currentStreakDays) 天 · 今日 \(ReadingStatsManager.shared.stats.todayMinutes)m"
    }

    private var streakRing: Color {
        let ratio = ReadingStatsManager.shared.stats.todayProgressRatio
        if ratio >= 1.0 { return Color(hex: "#7FB069") }
        if ratio >= 0.7 { return Color(hex: "#D08770") }
        return Color(hex: "#E5C07B")
    }

    // MARK: - Warm Empty Study View
    // Replaced by WarmEmptyStudyView below
}

// MARK: - Shelf Plank View
struct ShelfPlankView: View {
    var body: some View {
        VStack(spacing: 0) {
            // Shelf Top Surface Depth (层板上平面)
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(hex: "#5A3824"), // Specular reflection on wooden top edge
                            Color(hex: "#3D2416"),
                            Color(hex: "#2C180E")
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(height: 10)
                .overlay(
                    // Top Highlight line simulating warm chandelier light catching the shelf lip
                    Rectangle()
                        .fill(Color(hex: "#8C5839").opacity(0.85))
                        .frame(height: 0.5),
                    alignment: .top
                )

            // Shelf Front Beveled Edge (层板前立面厚度)
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [Color(hex: "#24140C"), Color(hex: "#180D07")],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(height: 14)
                .overlay(
                    // Bottom Bevel shadow
                    Rectangle()
                        .fill(Color.black.opacity(0.5))
                        .frame(height: 1),
                    alignment: .bottom
                )

            // Deep Drop Shadow cast onto wall below
            LinearGradient(
                colors: [
                    Color.black.opacity(0.68),
                    Color.black.opacity(0.35),
                    Color.clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 20)
        }
    }
}

// MARK: - Antique Brass Bookends (古典雕花黄铜书立)
struct LeftBrassBookendView: View {
    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            // Base shelf plate
            ZStack(alignment: .bottomTrailing) {
                // Diagonal metal brace
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 160))
                    path.addLine(to: CGPoint(x: 18, y: 160))
                    path.addLine(to: CGPoint(x: 18, y: 20))
                    path.closeSubpath()
                }
                .fill(
                    LinearGradient(
                        colors: [
                            Color(hex: "#B8860B").opacity(0.3),
                            Color(hex: "#8B6508").opacity(0.65)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 18, height: 160)

                // Upright brass plate hugging the book spine
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(hex: "#F9D976"),
                                Color(hex: "#E5A93C"),
                                Color(hex: "#A67C1E"),
                                Color(hex: "#5C3E08")
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 5, height: 175)
                    .clipShape(RoundedRectangle(cornerRadius: 2.5))
                    .overlay(
                        // Specular shine line
                        Rectangle()
                            .fill(Color.white.opacity(0.4))
                            .frame(width: 0.8),
                        alignment: .trailing
                    )
            }
        }
        .frame(width: 22, height: 180, alignment: .bottom)
        .shadow(color: .black.opacity(0.4), radius: 3, x: -1, y: 2)
    }
}

struct RightBrassBookendView: View {
    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                // Diagonal metal brace
                Path { path in
                    path.move(to: CGPoint(x: 18, y: 160))
                    path.addLine(to: CGPoint(x: 0, y: 160))
                    path.addLine(to: CGPoint(x: 0, y: 20))
                    path.closeSubpath()
                }
                .fill(
                    LinearGradient(
                        colors: [
                            Color(hex: "#B8860B").opacity(0.3),
                            Color(hex: "#8B6508").opacity(0.65)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 18, height: 160)

                // Upright brass plate hugging the book page edge
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(hex: "#F9D976"),
                                Color(hex: "#E5A93C"),
                                Color(hex: "#A67C1E"),
                                Color(hex: "#5C3E08")
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 5, height: 175)
                    .clipShape(RoundedRectangle(cornerRadius: 2.5))
                    .overlay(
                        // Specular shine line
                        Rectangle()
                            .fill(Color.white.opacity(0.4))
                            .frame(width: 0.8),
                        alignment: .leading
                    )
            }
        }
        .frame(width: 22, height: 180, alignment: .bottom)
        .shadow(color: .black.opacity(0.4), radius: 3, x: 1, y: 2)
    }
}

// MARK: - Single Shelf Row with Symmetrical Centering & Solid Plank
private struct SingleShelfRowView: View {
    let books: [EPUBBook]
    let isLastRow: Bool
    let onSelectBook: (EPUBBook) -> Void
    let onImportEPUB: () -> Void
    var onOpenXRay: ((EPUBBook) -> Void)? = nil
    var onResetProgress: ((UUID) -> Void)? = nil
    var onDeleteBook: ((UUID) -> Void)? = nil
    var chineseScriptMode: ChineseScriptMode = .original

    var body: some View {
        VStack(spacing: 0) {
            // Books standing on top of shelf, centered symmetrically with brass bookends
            HStack(alignment: .bottom, spacing: 0) {
                Spacer(minLength: 20)

                // Left Antique Brass Bookend
                LeftBrassBookendView()
                    .padding(.trailing, 6)

                // Center Book Items
                HStack(alignment: .bottom, spacing: 28) {
                    ForEach(books) { book in
                        RealisticBookItemView(
                            book: book,
                            onOpen: {
                                onSelectBook(book)
                            },
                            onOpenXRay: {
                                onOpenXRay?(book)
                            },
                            onResetProgress: {
                                onResetProgress?(book.id)
                            },
                            onDelete: {
                                onDeleteBook?(book.id)
                            },
                            chineseScriptMode: chineseScriptMode
                        )
                    }

                    // If last row and there is space, show "+ 放入新书" slot
                    if isLastRow && books.count < 4 {
                        AddBookSlotView(onImport: onImportEPUB)
                    }
                }

                // Right Antique Brass Bookend
                RightBrassBookendView()
                    .padding(.leading, 6)

                Spacer(minLength: 20)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 2) // Sits directly on shelf surface

            // Physical Wooden Shelf Plank
            ShelfPlankView()
        }
    }
}

// MARK: - Curated Heritage Masterpieces Shelf (典藏名著 · 置入书斋)
private struct CuratedClassicsShelfView: View {
    let classics: [ChineseClassicsRegistry.ClassicBook]
    let onAddClassic: (ChineseClassicsRegistry.ClassicBook) -> Void

    var body: some View {
        VStack(spacing: 12) {
            // Shelf Plaque / Brass Header
            HStack(spacing: 8) {
                Image(systemName: "books.vertical.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: "#D4AF37"))

                Text("典藏名著 · 一键置入书斋")
                    .font(.system(size: 14, weight: .bold, design: .serif))
                    .foregroundStyle(Color(hex: "#F5E6C8"))

                Text("公版中华古典巨著 · 轻点直接下载入库")
                    .font(.system(size: 11, design: .serif))
                    .foregroundStyle(Color(hex: "#CBB393").opacity(0.65))

                Spacer()
            }
            .padding(.horizontal, 32)
            .padding(.top, 16)

            // Books Shelf Row
            HStack(alignment: .bottom, spacing: 0) {
                Spacer(minLength: 20)

                LeftBrassBookendView()
                    .padding(.trailing, 6)

                HStack(alignment: .bottom, spacing: 28) {
                    ForEach(classics.prefix(4)) { classic in
                        CuratedClassicBookCard(
                            classic: classic,
                            onAdd: {
                                onAddClassic(classic)
                            }
                        )
                    }
                }

                RightBrassBookendView()
                    .padding(.leading, 6)

                Spacer(minLength: 20)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 2)

            ShelfPlankView()
        }
    }
}

// MARK: - Curated Classic Book Card (古典名著立体书模与一键入架)
private struct CuratedClassicBookCard: View {
    let classic: ChineseClassicsRegistry.ClassicBook
    let onAdd: () -> Void

    @State private var isHovered: Bool = false
    @State private var isAdding: Bool = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottom) {
                // Contact Shadow
                Ellipse()
                    .fill(Color.black.opacity(isHovered ? 0.35 : 0.45))
                    .frame(width: 136, height: 16)
                    .blur(radius: isHovered ? 6 : 3)
                    .offset(y: isHovered ? 12 : 6)

                // 3D Hardcover Body
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color(hex: classic.colorHex1), Color(hex: classic.colorHex2)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    // Subtle Leather/Canvas Texture Grain
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)

                    // Embossed Golden Filigree Frame
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(Color(hex: classic.goldHex).opacity(0.4), lineWidth: 1)
                        .padding(8)

                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .stroke(Color(hex: classic.goldHex).opacity(0.2), lineWidth: 0.5)
                        .padding(11)

                    // Cover Typography
                    VStack(spacing: 6) {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(hex: classic.goldHex).opacity(0.75))
                            .padding(.top, 18)

                        Spacer()

                        Text(classic.title)
                            .font(.system(size: 14, weight: .bold, design: .serif))
                            .foregroundStyle(Color(hex: classic.goldHex))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .padding(.horizontal, 10)

                        Rectangle()
                            .fill(Color(hex: classic.goldHex).opacity(0.5))
                            .frame(width: 28, height: 1)

                        Text(classic.author)
                            .font(.system(size: 11, weight: .medium, design: .serif))
                            .foregroundStyle(Color(hex: classic.goldHex).opacity(0.8))
                            .lineLimit(1)

                        Spacer()

                        Text(classic.publishYear)
                            .font(.system(size: 9, weight: .semibold, design: .serif))
                            .foregroundStyle(Color(hex: classic.goldHex).opacity(0.65))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.25))
                            .clipShape(Capsule())
                            .padding(.bottom, 14)
                    }

                    // Spine Shadow & Groove
                    HStack {
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.18),
                                Color.black.opacity(0.25),
                                Color.white.opacity(0.08),
                                Color.clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: 14)

                        Spacer()
                    }

                    // Spine Hinge Line
                    HStack {
                        Rectangle()
                            .fill(Color.black.opacity(0.35))
                            .frame(width: 1)
                            .offset(x: 14)
                        Spacer()
                    }
                }
                .frame(width: 140, height: 204)

                // Hover "一键入架" Banner overlay
                if isHovered || isAdding {
                    Button(action: {
                        isAdding = true
                        onAdd()
                    }) {
                        HStack(spacing: 4) {
                            if isAdding {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(width: 12, height: 12)
                            } else {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 11))
                            }
                            Text(isAdding ? "置入中..." : "置入书斋")
                                .font(.system(size: 11, weight: .semibold, design: .serif))
                        }
                        .foregroundStyle(Color(hex: "#1E120A"))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            LinearGradient(
                                colors: [Color(hex: "#F9D976"), Color(hex: "#E5A93C")],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .clipShape(Capsule())
                        .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                        .padding(.bottom, 18)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .offset(y: isHovered ? -8 : 0)
            .scaleEffect(isHovered ? 1.025 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isHovered)
        }
        .onHover { isHovered = $0 }
        .help("一键将《\(classic.title)》置入个人书架")
    }
}

// MARK: - Warm Empty Study View (典雅私人书斋迎宾屏)
private struct WarmEmptyStudyView: View {
    let onImportEPUB: () -> Void
    var onOpenOnlineHub: (() -> Void)? = nil
    var onOpenWeChatSync: (() -> Void)? = nil
    var onOpenGlobalNotebooks: (() -> Void)? = nil
    let recommendedClassics: [ChineseClassicsRegistry.ClassicBook]
    let onAddClassic: (ChineseClassicsRegistry.ClassicBook) -> Void

    var body: some View {
        VStack(spacing: 32) {
            // Study Welcome Plaque
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color(hex: "#D4AF37").opacity(0.12))
                        .frame(width: 72, height: 72)

                    Image(systemName: "lamp.desk.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(Color(hex: "#F3D084"))
                }

                Text("欢迎入座 DReader 私人书斋")
                    .font(.system(size: 20, weight: .bold, design: .serif))
                    .foregroundStyle(Color(hex: "#F5E6C8"))

                Text("阁下书架尚无藏书。可从本地导入 EPUB，或直接一键置入传世名著开卷品读。")
                    .font(.system(size: 13, design: .serif))
                    .foregroundStyle(Color(hex: "#CBB393").opacity(0.75))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)

                // Quick Action Buttons
                HStack(spacing: 16) {
                    Button(action: onImportEPUB) {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 12))
                            Text("从电脑导入 EPUB 电子书")
                                .font(.system(size: 12, weight: .semibold, design: .serif))
                        }
                        .foregroundStyle(Color(hex: "#1E120A"))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            LinearGradient(
                                colors: [Color(hex: "#F9D976"), Color(hex: "#D4AF37")],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                    }
                    .buttonStyle(.plain)

                    if let onOpenOnlineHub = onOpenOnlineHub {
                        Button(action: onOpenOnlineHub) {
                            HStack(spacing: 6) {
                                Image(systemName: "globe.asia.australia.fill")
                                    .font(.system(size: 12))
                                Text("探索在线海量书库...")
                                    .font(.system(size: 12, weight: .medium, design: .serif))
                            }
                            .foregroundStyle(Color(hex: "#F5E6C8"))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.08))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.white.opacity(0.15), lineWidth: 0.8)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }

                    if let onOpenWeChatSync = onOpenWeChatSync {
                        Button(action: onOpenWeChatSync) {
                            HStack(spacing: 6) {
                                Image(systemName: "quote.bubble.fill")
                                    .font(.system(size: 12))
                                Text("同步微信读书划线...")
                                    .font(.system(size: 12, weight: .medium, design: .serif))
                            }
                            .foregroundStyle(Color(hex: "#A7F3D0"))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color(hex: "#07C160").opacity(0.18))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color(hex: "#07C160").opacity(0.35), lineWidth: 0.8)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }

                    if let onOpenGlobalNotebooks = onOpenGlobalNotebooks {
                        Button(action: onOpenGlobalNotebooks) {
                            HStack(spacing: 6) {
                                Image(systemName: "highlighter")
                                    .font(.system(size: 12))
                                Text("全部划线与思考回顾...")
                                    .font(.system(size: 12, weight: .medium, design: .serif))
                            }
                            .foregroundStyle(Color(hex: "#FDE68A"))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.orange.opacity(0.18))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.orange.opacity(0.35), lineWidth: 0.8)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 4)
            }
            .padding(.vertical, 16)

            // Direct Curated Classics Bookshelf on first load
            if !recommendedClassics.isEmpty {
                CuratedClassicsShelfView(
                    classics: recommendedClassics,
                    onAddClassic: onAddClassic
                )
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }
}

// MARK: - Add Book Slot
private struct AddBookSlotView: View {
    let onImport: () -> Void
    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: onImport) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        Color(hex: "#E5C07B").opacity(isHovered ? 0.6 : 0.25),
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                    )
                    .background(Color.black.opacity(isHovered ? 0.25 : 0.12))
                    .frame(width: 140, height: 204)

                VStack(spacing: 8) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 24))
                        .foregroundStyle(Color(hex: "#E5C07B").opacity(isHovered ? 0.9 : 0.5))

                    Text("放入新书")
                        .font(.system(size: 12, weight: .medium, design: .serif))
                        .foregroundStyle(Color(hex: "#F5E6C8").opacity(isHovered ? 0.9 : 0.6))

                    Text("支持拖入 .epub")
                        .font(.system(size: 9))
                        .foregroundStyle(Color(hex: "#CBB393").opacity(0.4))
                }
            }
            .offset(y: isHovered ? -4 : 0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("导入本地 EPUB 电子书到书架")
    }
}

// MARK: - 书架顶栏统一功能按钮（暗玻璃雕花铜牌风格）
// 设计原则：无彩 chrome——所有功能按钮共用同一套暗玻璃材质与黄铜细描边，
// 唯一允许的彩色是「今日复习」的到期角标（唯一需要用户行动的信号）。
private struct ShelfTopBarButton: View {
    let icon: String
    let label: String
    var badgeCount: Int? = nil
    var ring: Color? = nil
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let ring {
                    ZStack {
                        Circle()
                            .stroke(ring.opacity(0.3), lineWidth: 2)
                            .frame(width: 13, height: 13)
                        Circle()
                            .trim(from: 0, to: ReadingStatsManager.shared.stats.todayProgressRatio)
                            .stroke(ring, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .frame(width: 13, height: 13)
                            .rotationEffect(.degrees(-90))
                    }
                }

                Image(systemName: icon)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color(hex: "#CBB393").opacity(0.9))

                Text(label)
                    .font(.system(size: 12, weight: .medium, design: .serif))
                    .foregroundStyle(Color(hex: "#E8DCC5"))

                if let badgeCount {
                    Text("\(badgeCount)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4.5)
                        .padding(.vertical, 1)
                        .background(Color(hex: "#C25E3A"))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.black.opacity(isHovered ? 0.5 : 0.35))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color(hex: "#B08D57").opacity(isHovered ? 0.55 : 0.3), lineWidth: 0.6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
