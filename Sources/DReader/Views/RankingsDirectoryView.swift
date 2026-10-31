//
//  RankingsDirectoryView.swift
//  DReader
//
//  书单榜单目录：书架层的第四个子页面（与在线书库同一套外壳骨架，砍掉中栏筛选列）。
//  左栏 = 榜单目录（微信读书三榜直连 / 豆瓣快照 / 国际奖项快照）；
//  中栏 = 书目网格（排名章 + 来源徽章 + 评分）；
//  右栏 = 详情抽屉（按来源给出试读/入架/外链动作）。
//

import SwiftUI
import AppKit

// MARK: - 浏览模型

/// 榜单页局部状态机：当前目录 / 书目 / 拉取态 / 动作记账（按 RankingBook.id）。
@MainActor
final class RankingBrowseModel: ObservableObject {
    private let vm: ReaderViewModel

    @Published var currentCatalog: RankingCatalog
    @Published var books: [RankingBook] = []
    @Published var selection: RankingBook?
    @Published var isLoading = false
    @Published var loadError: String?
    @Published var isStale = false
    @Published var refreshedAt: Date?
    @Published var isLoadingMore = false
    @Published var hasMorePages = true
    /// 动作进度（试读/整本/入架），key = 书目 id
    @Published var actionProgress: [String: Double] = [:]
    /// 动作过程中的状态文案
    @Published var actionMessage: [String: String] = [:]
    /// 已完成动作的落款（如「已入架」）
    @Published var actionDone: [String: String] = [:]

    init(vm: ReaderViewModel, catalog: RankingCatalog? = nil) {
        self.vm = vm
        self.currentCatalog = catalog ?? (RankingsRegistry.allCatalogs.first ??
            RankingCatalog(id: "empty", title: "—", subtitle: nil, source: .weread,
                           isLive: false, refreshInterval: nil, language: .zh))
    }

    // MARK: 目录切换与刷新

    func select(_ catalog: RankingCatalog) {
        guard catalog.id != currentCatalog.id else { return }
        currentCatalog = catalog
        selection = nil
        books = []
        loadError = nil
        isStale = false
        hasMorePages = true
        refreshedAt = nil
        Task { await refresh(force: false) }
    }

    func refresh(force: Bool) async {
        guard !isLoading else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let result = try await RankingService.shared.load(catalog: currentCatalog, force: force)
            books = result.books
            isStale = result.isStale
            refreshedAt = result.fetchedAt
            // 非实时目录无分页；实时目录按整页拉取，先假定还有下一页
            hasMorePages = currentCatalog.isLive
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if books.isEmpty { books = [] }
        }
    }

    func loadMore() async {
        guard currentCatalog.isLive, hasMorePages, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let appended = try await RankingService.shared.loadMore(catalog: currentCatalog)
            if let appended {
                books.append(contentsOf: appended)
            } else {
                hasMorePages = false
            }
        } catch {
            // 分页失败不打断已有内容，藏一档「再试一次」交由刷新按钮处理
            hasMorePages = false
        }
    }

    // MARK: - 微信读书动作（试读 / 整本入架）

    /// 微信读书试读：前 3 章抓取 → 临时 EPUB → 以 .rankings 来源进入阅读器。
    func previewWeread(_ book: RankingBook) {
        guard let bookId = book.wereadBookId else { return }
        guard actionProgress[book.id] == nil else { return }
        guard WeReadContentService.shared.hasCookie else {
            actionMessage[book.id] = "需要先登录微信读书（书架 → 在线书库 → 微信读书书架，扫码登录）"
            return
        }
        actionProgress[book.id] = 0.01
        actionMessage.removeValue(forKey: book.id)
        actionDone.removeValue(forKey: book.id)
        Task { [weak self] in
            guard let self else { return }
            do {
                let service = WeReadContentService.shared
                let catalog = try await service.previewCatalog(bookId: bookId)
                guard !catalog.chapters.isEmpty else {
                    throw WeReadContentService.WeReadContentError.noChapters
                }
                let total = catalog.chapters.count
                let previewChapters = Array(catalog.chapters.prefix(3))
                let fetched = try await WeReadEPUBAssembler.fetchWholeBook(
                    bookId: bookId,
                    chapters: previewChapters,
                    onProgress: { [weak self] done, doneTotal, chapterTitle in
                        let progress = min(0.9, Double(doneTotal) > 0
                            ? Double(done + 1) / Double(doneTotal) * 0.85 + 0.05
                            : 0.9)
                        let label = chapterTitle.isEmpty ? "" : "（\(chapterTitle)）"
                        let status = "抓取 \(done + 1)/\(previewChapters.count) 章\(label)"
                        Task { @MainActor [weak self] in
                            self?.actionProgress[book.id] = progress
                            self?.actionMessage[book.id] = status
                        }
                    }
                )
                actionProgress[book.id] = 0.92
                actionMessage[book.id] = "组装试读…"
                let fm = FileManager.default
                let previewDir = fm.temporaryDirectory
                    .appendingPathComponent("DReaderPreviews", isDirectory: true)
                try fm.createDirectory(at: previewDir, withIntermediateDirectories: true)
                let tempURL = previewDir.appendingPathComponent("微信试读-\(bookId).epub")
                try WeReadEPUBAssembler.packageEPUB(
                    bookId: bookId,
                    title: "\(book.title)（试读）",
                    author: book.author.isEmpty ? "WeRead" : book.author,
                    chapters: fetched,
                    css: nil,
                    outputURL: tempURL
                )
                let parsed = try await EPUBParser.shared.parse(fileURL: tempURL)
                vm.enterPreview(
                    book: parsed,
                    meta: .weread(bookId: bookId, title: book.title, author: book.author, cover: book.coverURL?.absoluteString ?? ""),
                    totalChapters: total,
                    origin: .rankings
                )
                actionProgress[book.id] = nil
                actionMessage.removeValue(forKey: book.id)
            } catch {
                actionProgress[book.id] = nil
                actionMessage[book.id] = "《\(book.title)》试读失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            }
        }
    }

    /// 微信读书全本入架（与在线书库 downloadWereadBook 同管线：验证目录 → 整本抓取 → 组装 → 落 DownloadedBooks）。
    func downloadWereadFull(_ book: RankingBook) {
        guard let bookId = book.wereadBookId else { return }
        if actionProgress[book.id] != nil { return }
        guard WeReadContentService.shared.hasCookie else {
            actionMessage[book.id] = "需要先登录微信读书（书架 → 在线书库 → 微信读书书架，扫码登录）"
            return
        }
        actionProgress[book.id] = 0.01
        actionMessage[book.id] = "验证目录…"
        actionDone.removeValue(forKey: book.id)
        Task { [weak self] in
            guard let self else { return }
            do {
                let service = WeReadContentService.shared
                let catalog = try await service.previewCatalog(bookId: bookId)
                guard !catalog.chapters.isEmpty else {
                    throw WeReadContentService.WeReadContentError.noChapters
                }
                let title = catalog.title.isEmpty ? book.title : catalog.title
                let fetched = try await WeReadEPUBAssembler.fetchWholeBook(
                    bookId: bookId,
                    chapters: catalog.chapters,
                    onProgress: { [weak self] done, doneTotal, _ in
                        let progress = Double(done) / Double(max(1, doneTotal))
                        let status = "抓取 \(done + 1)/\(doneTotal) 章"
                        Task { @MainActor [weak self] in
                            self?.actionProgress[book.id] = progress
                            self?.actionMessage[book.id] = status
                        }
                    }
                )
                actionProgress[book.id] = 0.97
                actionMessage[book.id] = "组装 EPUB…"
                let fm = FileManager.default
                let shelfDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                    .appendingPathComponent("DReader/DownloadedBooks", isDirectory: true)
                try fm.createDirectory(at: shelfDir, withIntermediateDirectories: true)
                let safeTitle = title.replacingOccurrences(of: "/", with: "_")
                let outputURL = shelfDir.appendingPathComponent("《\(safeTitle)》(微信读书).epub")
                try WeReadEPUBAssembler.packageEPUB(
                    bookId: bookId,
                    title: title,
                    author: book.author.isEmpty ? "WeRead" : book.author,
                    chapters: fetched,
                    css: nil,
                    outputURL: outputURL
                )
                actionProgress[book.id] = nil
                actionMessage.removeValue(forKey: book.id)
                actionDone[book.id] = "已入架"
                NotificationCenter.default.post(name: .init("DReaderReloadShelf"), object: nil)
                await vm.openEPUB(url: outputURL)
            } catch is CancellationError {
                actionProgress[book.id] = nil
                actionMessage.removeValue(forKey: book.id)
            } catch {
                actionProgress[book.id] = nil
                actionMessage[book.id] = "下载失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            }
        }
    }

    // MARK: - 静态榜动作（公版书一键入架 / 外链）

    /// 公版书一键入架：走 Gutenberg 下载 → importBookToLibrary 全管线。
    func downloadCurated(_ book: RankingBook) {
        guard let gid = book.gutenbergID, !gid.isEmpty else { return }
        guard actionProgress[book.id] == nil else { return }
        actionProgress[book.id] = 0.02
        actionMessage.removeValue(forKey: book.id)
        actionDone.removeValue(forKey: book.id)
        Task { [weak self] in
            guard let self else { return }
            do {
                let item = OnlineBookItem(
                    id: "curated-gutenberg-\(gid)",
                    title: book.title,
                    author: book.author,
                    source: .gutenberg,
                    coverURL: book.coverURL,
                    downloadURL: URL(string: "https://www.gutenberg.org/cache/epub/\(gid)/pg\(gid).epub"),
                    candidateURLs: [
                        URL(string: "https://www.gutenberg.org/cache/epub/\(gid)/pg\(gid).epub"),
                        URL(string: "https://www.gutenberg.org/ebooks/\(gid).epub.noimages")
                    ].compactMap { $0 },
                    gutenbergID: gid,
                    fileExtension: "epub",
                    publishYear: book.year,
                    language: book.language == .en ? "English" : "多语",
                    isPublicDomain: true,
                    description: book.summary
                )
                let localURL = try await OnlineBookService.shared.downloadEPUB(item: item) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.actionProgress[book.id] = progress
                    }
                }
                actionProgress[book.id] = nil
                actionDone[book.id] = "已入架"
                await vm.openEPUB(url: localURL)
            } catch {
                actionProgress[book.id] = nil
                actionMessage[book.id] = "《\(book.title)》下载失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            }
        }
    }

    func openExternal(_ book: RankingBook) {
        guard let url = book.externalURL else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - 视图

struct RankingsDirectoryView: View {
    @StateObject private var model: RankingBrowseModel
    private weak var vm: ReaderViewModel?

    init(vm: ReaderViewModel) {
        _model = StateObject(wrappedValue: RankingBrowseModel(vm: vm))
        self.vm = vm
    }

    private var catalog: RankingCatalog { model.currentCatalog }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.1)
            HStack(spacing: 0) {
                catalogListColumn
                    .frame(width: 224)
                Divider().opacity(0.12)
                mediaColumn
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .task(id: catalog.id) {
            await model.refresh(force: false)
        }
    }

    // MARK: 顶栏

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                vm?.returnToBookshelf()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("书架")
                        .font(.system(size: 12.5, weight: .medium))
                }
                .foregroundStyle(Color.primary.opacity(0.8))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
            }
            .buttonStyle(.plain)

            Image(systemName: "trophy.fill")
                .font(.system(size: 14))
                .foregroundStyle(Color(hex: "#9E7A45"))
            Text("书单榜单")
                .font(.system(size: 15, weight: .bold, design: .serif))
                .foregroundStyle(.primary)

            if model.isStale {
                Label("网络拉取失败 · 已回退缓存", systemImage: "wifi.exclamationmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.red.opacity(0.85))
            } else if let at = model.refreshedAt {
                Text("数据截至 \(at.formatted(.relative(presentation: .named)))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary.opacity(0.8))
            }

            Spacer()

            if catalog.isLive {
                Button {
                    Task { await model.refresh(force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(model.isLoading ? 360 : 0))
                        .animation(model.isLoading
                            ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                            : .default, value: model.isLoading)
                }
                .buttonStyle(.plain)
                .disabled(model.isLoading)
                .help("立即刷新该榜单")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // MARK: 左栏（榜单目录）

    private var catalogListColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                let grouped = groupedCatalogs
                ForEach(Array(grouped.enumerated()), id: \.offset) { _, group in
                    sectionLabel(group.group)
                    ForEach(group.items) { catalog in
                        catalogRow(catalog)
                    }
                }
            }
            .padding(14)
        }
        .frame(maxHeight: .infinity)
    }

    /// 依据注册表顺序把目录分成三节（微信直连 / 榜单快照 / 国际奖项）
    private var groupedCatalogs: [(group: RankingSource, items: [RankingCatalog])] {
        var result: [(group: RankingSource, items: [RankingCatalog])] = []
        for catalog in RankingsRegistry.allCatalogs {
            if let last = result.last, last.group == catalog.source {
                result[result.count - 1].items.append(catalog)
            } else {
                result.append((catalog.source, [catalog]))
            }
        }
        return result
    }

    private func sectionLabel(_ source: RankingSource) -> some View {
        Text(source.sectionLabel)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Color.secondary.opacity(0.75))
            .padding(.top, 12)
            .padding(.bottom, 5)
            .padding(.leading, 6)
    }

    private func catalogRow(_ catalog: RankingCatalog) -> some View {
        let (icon, iconColor) = Self.sourceGlyph(catalog.source)
        let active = catalog.id == model.currentCatalog.id
        return Button {
            model.select(catalog)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(iconColor)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(catalog.title)
                        .font(.system(size: 12.5, weight: active ? .semibold : .regular))
                        .lineLimit(1)
                    if let subtitle = catalog.subtitle {
                        Text(subtitle)
                            .font(.system(size: 9))
                            .foregroundStyle(Color.secondary.opacity(0.7))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Text(catalog.isLive ? "直连" : "快照")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(catalog.isLive
                        ? Color.green.opacity(0.75)
                        : Color.secondary.opacity(0.65))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill((catalog.isLive ? Color.green : Color.secondary).opacity(0.1)))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(active ? Color.primary.opacity(0.08) : Color.primary.opacity(0.02))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(active ? Color(hex: "#9E7A45").opacity(0.45) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private static func sourceGlyph(_ source: RankingSource) -> (String, Color) {
        switch source {
        case .weread: return ("book.pages", Color(hex: "#1F9E51"))
        case .douban: return ("leaf.fill", Color(hex: "#00B51A"))
        case .curated: return ("medal.fill", Color(hex: "#9E7A45"))
        }
    }

    // MARK: 中栏（书目网格 + 详情抽屉）

    private var mediaColumn: some View {
        HStack(spacing: 0) {
            ZStack {
                if model.isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.regular)
                        Text("正在加载…")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                } else if let loadError = model.loadError, model.books.isEmpty {
                    emptyBooksState(
                        icon: "cloud.slash",
                        hint: loadError,
                        showRetry: catalog.isLive
                    )
                } else if model.books.isEmpty {
                    emptyBooksState(icon: "books.vertical", hint: defaultEmptyHint, showRetry: false)
                } else {
                    bookGrid
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let selection = model.selection {
                Divider().opacity(0.12)
                detailDrawer(selection)
                    .frame(width: 298)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.selection?.id)
    }

    private var defaultEmptyHint: String {
        switch catalog.source {
        case .weread: return "榜单暂时拉不到内容，稍后点右上角刷新再试。"
        case .douban: return "快照数据为空。"
        case .curated: return "这份奖项书单为空。"
        }
    }

    private func emptyBooksState(icon: String, hint: String, showRetry: Bool) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundStyle(Color.secondary.opacity(0.4))
            Text(hint)
                .font(.system(size: 12, weight: .medium, design: .serif))
                .foregroundStyle(Color.secondary.opacity(0.75))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            if showRetry {
                Button {
                    Task { await model.refresh(force: true) }
                } label: {
                    Label("重试", systemImage: "arrow.clockwise")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.75))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bookGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 138, maximum: 190), spacing: 14)],
                spacing: 16
            ) {
                ForEach(model.books) { book in
                    bookCard(book)
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                model.selection = book
                            }
                        }
                }
            }
            .padding(18)

            if catalog.isLive, model.hasMorePages, model.books.count >= 20, !model.isLoadingMore {
                loadMoreFooter
            } else if model.isLoadingMore {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("加载更多…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 18)
            }
        }
    }

    private var loadMoreFooter: some View {
        HStack {
            Spacer()
            Button {
                Task { await model.loadMore() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down.circle")
                    Text("加载更多")
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.75))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.primary.opacity(0.07), in: Capsule())
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.bottom, 18)
    }

    // MARK: 书卡

    private func bookCard(_ book: RankingBook) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            cover(book)
                .frame(width: 138, height: 192)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    rankPill(book.rank)
                        .padding(6)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 0.6)
                )
                .shadow(color: .black.opacity(0.12), radius: 5, y: 2)

            Text(book.title)
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(book.author)
                .font(.system(size: 10))
                .foregroundStyle(Color.secondary.opacity(0.8))
                .lineLimit(1)

            HStack(spacing: 6) {
                sourceBadge(book)
                Spacer(minLength: 0)
                if let rating = book.rating {
                    HStack(spacing: 2) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8.5))
                            .foregroundStyle(Color(hex: "#E5A93C"))
                        Text(String(format: "%.1f", rating))
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                    }
                    .foregroundStyle(Color.primary.opacity(0.7))
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(model.selection?.id == book.id ? Color.primary.opacity(0.06) : Color.primary.opacity(0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    model.selection?.id == book.id ? Color(hex: "#9E7A45").opacity(0.5) : Color.primary.opacity(0.07),
                    lineWidth: 1
                )
        )
        .contentShape(Rectangle())
    }

    /// 排名章：前三名白底金/银/铜字，其余深底白字
    private func rankPill(_ rank: Int) -> some View {
        Group {
            if rank <= 3 {
                let tint: Color = rank == 1 ? Color(hex: "#C89A2A")
                    : rank == 2 ? Color(hex: "#8E939C") : Color(hex: "#B06A3B")
                Text("#\(rank)")
                    .font(.system(size: 9.5, weight: .bold).monospacedDigit())
                    .foregroundStyle(tint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(Capsule().fill(Color.white.opacity(0.95)))
            } else {
                Text("#\(rank)")
                    .font(.system(size: 9.5, weight: .bold).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.92))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(Capsule().fill(Color.black.opacity(0.45)))
            }
        }
        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
    }

    private func sourceBadge(_ book: RankingBook) -> some View {
        Text(book.catalogID.contains("weread") ? "微信读书"
            : book.catalogID.contains("douban") ? "豆瓣" : "奖项书单")
            .font(.system(size: 8.5, weight: .medium))
            .foregroundStyle(Color.secondary.opacity(0.8))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.05)))
    }

    // MARK: 封面

    @ViewBuilder
    private func cover(_ book: RankingBook) -> some View {
        let url = book.displayCoverURL
        if let url, url.host?.contains("doubanio") == true {
            // 豆瓣 CDN 拒绝无 Referer 直连(418),AsyncImage 不可配头 → 走专用加载器
            DoubanCoverImage(url: url) {
                coverPlaceholder(book)
            }
        } else if let url {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    coverPlaceholder(book)
                }
            }
        } else {
            coverPlaceholder(book)
        }
    }

    /// 无封面：按书名生成稳定的渐变色字牌（书籍常青封面即如此）
    private func coverPlaceholder(_ book: RankingBook) -> some View {
        let tints = Self.placeholderTints
        let seed = book.title.unicodeScalars.map { Int($0.value) }.reduce(0, +)
        let pair = tints[seed % tints.count]
        return ZStack {
            LinearGradient(
                colors: [Color(hex: pair.0), Color(hex: pair.1)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            Text(String(book.title.prefix(6)))
                .font(.system(size: 12, weight: .semibold, design: .serif))
                .foregroundStyle(Color.white.opacity(0.92))
                .multilineTextAlignment(.center)
                .padding(8)
        }
    }

    private static let placeholderTints: [(String, String)] = [
        ("#B8925F", "#7B6144"),
        ("#4D6A8C", "#2F4557"),
        ("#6D7791", "#454D61"),
        ("#8A6D3B", "#5C4628"),
        ("#33605A", "#22423E"),
        ("#5C5470", "#3A3549")
    ]

    // MARK: 详情抽屉

    private func detailDrawer(_ book: RankingBook) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("书籍详情")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.secondary.opacity(0.75))
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) { model.selection = nil }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().opacity(0.1)

            HStack(alignment: .top, spacing: 12) {
                cover(book)
                    .frame(width: 84, height: 118)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))

                VStack(alignment: .leading, spacing: 6) {
                    Text(book.title)
                        .font(.system(size: 13, weight: .bold, design: .serif))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(book.author)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondary.opacity(0.85))
                    let chips: [String] = [
                        book.rating.map { String(format: "评分 %.1f", $0) },
                        book.readersText,
                        book.year.map { "\($0) 年" },
                        book.honor,
                        book.language == .mixed ? nil : book.language.badgeText,
                        book.isbn.map { "ISBN \($0)" }
                    ].compactMap { $0 }
                    if !chips.isEmpty {
                        FlowLayoutChips(items: chips, onSelect: { _ in })
                    }
                }
            }
            .padding(14)
            .padding(.top, 2)

            if let summary = book.summary, !summary.isEmpty {
                Divider().opacity(0.06)
                ScrollView {
                    Text(summary)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.primary.opacity(0.8))
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
                .frame(minHeight: 60)
            }

            Spacer(minLength: 0)

            if let message = model.actionMessage[book.id] {
                Text(message)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.red.opacity(0.85))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
            } else if let done = model.actionDone[book.id] {
                Label(done, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.green.opacity(0.85))
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
            }

            if let progress = model.actionProgress[book.id] {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(model.actionMessage[book.id] ?? "处理中…")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(progress * 100))%")
                            .font(.system(size: 9.5).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(Color(hex: "#9E7A45"))
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
            }

            Divider().opacity(0.1)
            actionRow(book)
                .padding(14)
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    @ViewBuilder
    private func actionRow(_ book: RankingBook) -> some View {
        VStack(spacing: 8) {
            switch catalog.source {
            case .weread:
                actionButton(
                    title: "试读前三章", icon: "book.pages", primary: true,
                    busy: model.actionProgress[book.id] != nil
                ) {
                    model.previewWeread(book)
                }
                actionButton(
                    title: "整本抓取入架", icon: "square.and.arrow.down", primary: false,
                    busy: model.actionProgress[book.id] != nil
                ) {
                    model.downloadWereadFull(book)
                }
                externalButton(book, label: "打开微信读书网页版")
            case .curated:
                if book.gutenbergID != nil {
                    actionButton(
                        title: "一键入架（公版 EPUB）", icon: "square.and.arrow.down", primary: true,
                        busy: model.actionProgress[book.id] != nil
                    ) {
                        model.downloadCurated(book)
                    }
                } else {
                    Text("版权原因，本书暂无在线下载入口。")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.secondary.opacity(0.7))
                }
                externalButton(book, label: "打开详情页面")
            case .douban:
                Text("版权原因，豆瓣榜仅作浏览参考，不能直接入架。")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.secondary.opacity(0.7))
                externalButton(book, label: "去豆瓣查看")
            }
        }
    }

    private func actionButton(
        title: String, icon: String, primary: Bool, busy: Bool, action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .serif))
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(primary ? Color(hex: "#241708") : Color.primary.opacity(0.85))
            .padding(.vertical, 8)
            .background(
                primary
                    ? AnyShapeStyle(LinearGradient(
                        colors: [Color(hex: "#F9D976"), Color(hex: "#D4AF37")],
                        startPoint: .top, endPoint: .bottom))
                    : AnyShapeStyle(Color.primary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(primary ? Color.clear : Color.primary.opacity(0.15), lineWidth: 0.8)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .opacity(busy ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    private func externalButton(_ book: RankingBook, label: String) -> some View {
        Button {
            model.openExternal(book)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 11))
                Text(label)
                    .font(.system(size: 11.5, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(Color.secondary.opacity(0.85))
            .padding(.vertical, 7)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.primary.opacity(0.15), lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
    }
}

/// 豆瓣 CDN(doubanio)封面加载:直连必须带 book.douban.com Referer(否则 418),
/// 而 AsyncImage 无法配置请求头 → 自管 URLSession + 内存缓存。
/// 其余来源(微信/gutenberg/Open Library)仍走 AsyncImage。
@MainActor
private enum DoubanCoverContext {
    static let cache = NSCache<NSURL, NSImage>()
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36",
            "Referer": "https://book.douban.com/"
        ]
        cfg.timeoutIntervalForRequest = 20
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()
}

private struct DoubanCoverImage<Placeholder: View>: View {
    let url: URL
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            if let hit = DoubanCoverContext.cache.object(forKey: url as NSURL) {
                image = hit
                return
            }
            guard let (data, resp) = try? await DoubanCoverContext.session.data(from: url),
                  (200..<300).contains((resp as? HTTPURLResponse)?.statusCode ?? 0),
                  let img = NSImage(data: data)
            else { return }
            DoubanCoverContext.cache.setObject(img, forKey: url as NSURL)
            image = img
        }
    }
}
