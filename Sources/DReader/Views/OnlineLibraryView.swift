import SwiftUI
import AppKit

// MARK: - 在线书库（书架层子页面，多栏代替旧弹窗中心）

/// 详情面板的选择对象：跨三类源统一抽象，右栏点书就地展开。
struct LibrarySelection: Identifiable, Equatable {
    enum Payload {
        case publicSearch(OnlineBookItem)
        case opds(OPDSService.Entry, OPDSService.Source)
        case weread(WeReadShelfService.ShelfBook)
    }
    // OnlineBookItem 不持 Equatable（元字段太多），跨 case 用业务 id 比较即可。
    static func == (lhs: LibrarySelection, rhs: LibrarySelection) -> Bool { lhs.id == rhs.id }
    let payload: Payload
    var id: String {
        switch payload {
        case .publicSearch(let item): return "pub-\(item.id)"
        case .opds(let entry, _): return "opds-\(entry.id)"
        case .weread(let book): return "weread-\(book.bookId)"
        }
    }
    var title: String {
        switch payload {
        case .publicSearch(let item): return item.title
        case .opds(let entry, _): return entry.title
        case .weread(let book): return book.title
        }
    }
    var author: String {
        switch payload {
        case .publicSearch(let item): return item.author
        case .opds(let entry, _): return entry.author
        case .weread(let book): return book.author
        }
    }
}

// MARK: - OPDS 浏览状态机（原 OPDSBrowsePanel 的模型搬移复用）
//
/// OPDS 的全部状态：书馆管理（表单/列表）与目录浏览（面包屑/搜索/下载）。
/// OPDS 是标准开放协议——连接只发生一次，之后就是纯粹的目录与取书，没有登录态会坏掉。
@MainActor
final class OPDSBrowseModel: ObservableObject {
    let onImport: (URL) -> Void

    init(onImport: @escaping (URL) -> Void) {
        self.onImport = onImport
    }

    // 书馆管理
    @Published var sources: [OPDSService.Source] = []
    @Published var showForm = false
    @Published var editingID: UUID? = nil
    @Published var formName = ""
    @Published var formURL = ""
    @Published var formUsername = ""
    @Published var formPassword = ""
    @Published var formAllowSelfSigned = false

    // 目录浏览
    enum Mode { case manage, browse }
    @Published var mode: Mode = .manage
    @Published var activeSource: OPDSService.Source? = nil
    /// 导航面包屑栈：stack[0] 是根目录，其余依次为进入的子目录
    @Published var stack: [OPDSService.Feed] = []
    /// 该书馆的目录内搜索模板（根 feed 常携带）
    @Published var searchTemplate: String? = nil
    @Published var searchQuery = ""
    @Published var isSearchResults = false
    @Published var searchFeed: OPDSService.Feed? = nil
    @Published var isLoading = false
    /// entryID → 下载进度（0...1），nil 即未在下载
    @Published var downloading: [String: Double] = [:]
    @Published var importedIDs: Set<String> = []
    @Published var errorMessage: String? = nil

    var currentFeed: OPDSService.Feed? {
        isSearchResults ? searchFeed : stack.last
    }

    var currentEntries: [OPDSService.Entry] { currentFeed?.entries ?? [] }

    func reloadSources() {
        sources = OPDSService.loadSources()
    }

    static func message(for error: Error) -> String {
        if let urlError = error as? URLError,
           urlError.code == .serverCertificateUntrusted || urlError.code == .serverCertificateHasUnknownRoot {
            return "证书不受信任（自签名证书的典型报错）。可在书馆设置里开启「接受自签名证书」"
        }
        return error.localizedDescription
    }

    // MARK: 书馆表单

    func beginAdd() {
        editingID = nil
        formName = ""
        formURL = ""
        formUsername = ""
        formPassword = ""
        formAllowSelfSigned = false
        showForm = true
    }

    func beginEdit(_ source: OPDSService.Source) {
        editingID = source.id
        formName = source.name
        formURL = source.url
        formUsername = source.username
        formPassword = source.password
        formAllowSelfSigned = source.allowSelfSigned
        showForm = true
    }

    func saveForm() {
        let trimmedURL = formURL.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmedURL),
              url.host != nil,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            errorMessage = "书馆地址需是 http:// 或 https:// 开头的完整 URL"
            return
        }
        let displayName = formName.isEmpty ? (url.host ?? "未命名书馆") : formName
        let account = formUsername.trimmingCharacters(in: .whitespaces)
        if let id = editingID, let idx = sources.firstIndex(where: { $0.id == id }) {
            sources[idx].name = displayName
            sources[idx].url = trimmedURL
            sources[idx].username = account
            sources[idx].password = formPassword
            sources[idx].allowSelfSigned = formAllowSelfSigned
        } else {
            sources.append(
                .init(name: displayName, url: trimmedURL, username: account, password: formPassword, allowSelfSigned: formAllowSelfSigned)
            )
        }
        OPDSService.saveSources(sources)
        if let active = activeSource {
            activeSource = sources.first { $0.id == active.id }
        }
        errorMessage = nil
        showForm = false
    }

    func deleteSource(_ source: OPDSService.Source) {
        sources.removeAll { $0.id == source.id }
        OPDSService.saveSources(sources)
        if activeSource?.id == source.id {
            activeSource = nil
            stack = []
            searchTemplate = nil
            searchFeed = nil
            isSearchResults = false
            mode = .manage
        }
        if editingID == source.id { showForm = false }
    }

    // MARK: 目录浏览

    func connect(_ source: OPDSService.Source) {
        activeSource = source
        stack = []
        isSearchResults = false
        searchFeed = nil
        errorMessage = nil
        mode = .browse
        Task { await loadAndSet(href: source.url, root: true) }
    }

    func back() {
        exitSearch()
        if stack.count > 1 {
            stack.removeLast()
        } else {
            mode = .manage
        }
    }

    func popTo(_ index: Int) {
        guard stack.indices.contains(index) else { return }
        exitSearch() // 在搜索结果里点面包屑要先退回目录态，否则 stack 变了视图还停在结果页
        stack.removeLast(stack.count - index - 1)
    }

    func openSub(_ entry: OPDSService.Entry) {
        guard let href = entry.subsectionHref else { return }
        exitSearch()
        Task { await loadAndSet(href: href, root: false) }
    }

    func exitSearch() {
        isSearchResults = false
        searchFeed = nil
    }

    func submitSearch() {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard let template = searchTemplate else {
            errorMessage = "这个书馆不提供目录内搜索"
            return
        }
        Task {
            isLoading = true
            defer { isLoading = false }
            do {
                searchFeed = try await OPDSService.shared.search(template: template, terms: trimmed, source: activeSource)
                isSearchResults = true
            } catch {
                errorMessage = Self.message(for: error)
            }
        }
    }

    func loadNextPage() {
        guard let next = currentFeed?.nextPageURL else { return }
        Task {
            isLoading = true
            defer { isLoading = false }
            do {
                let feed = try await OPDSService.shared.fetchFeed(href: next, source: activeSource)
                if searchTemplate == nil { searchTemplate = feed.searchURLTemplate }
                if isSearchResults, var results = searchFeed {
                    results.entries += feed.entries
                    results.nextPageURL = feed.nextPageURL
                    searchFeed = results
                } else if var top = stack.last {
                    top.entries += feed.entries
                    top.nextPageURL = feed.nextPageURL
                    stack[stack.count - 1] = top
                }
            } catch {
                errorMessage = Self.message(for: error)
            }
        }
    }

    private func loadAndSet(href: String, root: Bool) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let feed = try await OPDSService.shared.fetchFeed(href: href, source: activeSource)
            if searchTemplate == nil { searchTemplate = feed.searchURLTemplate }
            if root {
                stack = [feed]
            } else {
                stack.append(feed)
            }
        } catch {
            errorMessage = Self.message(for: error)
            if root { mode = .manage } // 连接失败退回书馆列表，错误条可见
        }
    }

    // MARK: 下载

    func download(_ entry: OPDSService.Entry) {
        guard let source = activeSource, downloading[entry.id] == nil else { return }
        downloading[entry.id] = 0.01
        Task {
            do {
                let url = try await OPDSService.shared.downloadEPUB(entry: entry, source: source) { [weak self] progress in
                    Task { @MainActor [weak self] in self?.downloading[entry.id] = progress }
                }
                importedIDs.insert(entry.id)
                downloading[entry.id] = nil
                onImport(url)
            } catch {
                downloading[entry.id] = nil
                errorMessage = "《\(entry.title)》下载失败：\(Self.message(for: error))"
            }
        }
    }
}

// MARK: - 在线书库统一状态

@MainActor
final class OnlineLibraryModel: ObservableObject {
    let vm: ReaderViewModel
    // var（而非 let）：$model.opds.xxx 的 Binding 需要 var 组成 ReferenceWritableKeyPath
    var opds: OPDSBrowseModel

    init(vm: ReaderViewModel) {
        self.vm = vm
        let importDispatch: (URL) -> Void = { [weak vm] url in
            Task { @MainActor in await vm?.openEPUB(url: url) }
        }
        self.opds = OPDSBrowseModel(onImport: importDispatch)
    }

    /// 当前激活的书源。OPDS 的具体馆保存在 opds.activeSource。
    enum ActiveKind: Equatable {
        case none
        case publicSearch(OnlineBookSource)
        case opds
        case weread
    }
    @Published var activeKind: ActiveKind = .none
    @Published var message: String? = nil
    @Published var selection: LibrarySelection? = nil

    // 试读/下载瞬态，按详情 id 记账
    @Published var previewProgress: [String: Double] = [:]
    @Published var previewMessage: [String: String] = [:]

    func onAppear() {
        opds.reloadSources()
        loadPersistedZLibAccount()
        refreshWereadState()
    }

    func report(_ text: String) {
        message = text
    }

    // MARK: 书源切换

    func activatePublicSource(_ source: OnlineBookSource) {
        activeKind = .publicSearch(source)
        searchQuery = ""
        searchResults = []
        message = nil
        selection = nil
        performSearch()
    }

    func openOPDS(_ source: OPDSService.Source?) {
        activeKind = .opds
        message = nil
        selection = nil
        if let source {
            opds.connect(source)
        } else {
            opds.mode = .manage
            opds.activeSource = nil
        }
    }

    func beginAddOPDSSource() {
        activeKind = .opds
        selection = nil
        opds.mode = .manage
        opds.activeSource = nil
        opds.beginAdd()
    }

    // MARK: 公共书库搜索（Open Library / Gutenberg / Z-Library）

    @Published var searchQuery = ""
    @Published var searchResults: [OnlineBookItem] = []
    @Published var isSearching = false
    @Published var downloadedItemIDs: Set<String> = []
    @Published var downloadProgress: [String: Double] = [:]

    @Published var zlibAccount = ZLibraryUserAccount()
    @Published var showZLibLogin = false
    @Published var loginEmailInput = ""
    @Published var loginKeyInput = ""

    private let quickChipsOpenLibrary = ["红楼梦", "道德经", "Pride and Prejudice", "Walden", "鲁迅"]
    private let quickChipsGutenberg = ["红楼梦", "道德经", "三国演义", "西游记", "水浒传", "论语", "孙子兵法", "唐诗三百首"]
    private let quickChipsZLibrary = ["纳瓦尔宝典", "原则", "置身事内", "思考，快与慢", "计算机系统"]

    func quickChips(for source: OnlineBookSource) -> [String] {
        switch source {
        case .openLibrary: return quickChipsOpenLibrary
        case .gutenberg: return quickChipsGutenberg
        case .zlibrary: return quickChipsZLibrary
        default: return []
        }
    }

    func performSearch() {
        guard case .publicSearch(let source) = activeKind else { return }
        let query = searchQuery.isEmpty ? (source == .openLibrary ? "Pride and Prejudice" : "红楼梦") : searchQuery
        Task {
            isSearching = true
            defer { isSearching = false }
            let account: ZLibraryUserAccount? = source == .zlibrary ? zlibAccount : nil
            let results = await OnlineBookService.shared.search(query: query, source: source, zlibraryAccount: account)
            searchResults = results
            if results.isEmpty { report("没有搜到相关书目，换个关键词试试") }
        }
    }

    func loginZLib() {
        Task {
            let account = await OnlineBookService.shared.loginZLibrary(email: loginEmailInput, userKey: loginKeyInput)
            zlibAccount = account
            persistZLibAccount(account)
            showZLibLogin = false
            loginEmailInput = account.email
            loginKeyInput = account.userKey
            if case .publicSearch(.zlibrary) = activeKind { performSearch() }
        }
    }

    private func persistZLibAccount(_ account: ZLibraryUserAccount) {
        if let data = try? JSONEncoder().encode(account) {
            UserDefaults.standard.set(data, forKey: "dreader.zlib_account")
        }
    }

    private func loadPersistedZLibAccount() {
        if let data = UserDefaults.standard.data(forKey: "dreader.zlib_account"),
           let account = try? JSONDecoder().decode(ZLibraryUserAccount.self, from: data) {
            zlibAccount = account
            loginEmailInput = account.email
            loginKeyInput = account.userKey
        }
    }

    func downloadPublic(_ item: OnlineBookItem) {
        guard downloadProgress[item.id] == nil else { return }
        downloadProgress[item.id] = 0.01
        Task {
            do {
                let url = try await OnlineBookService.shared.downloadEPUB(item: item) { [weak self] progress in
                    Task { @MainActor [weak self] in self?.downloadProgress[item.id] = progress }
                }
                downloadedItemIDs.insert(item.id)
                downloadProgress[item.id] = nil
                if item.source == .zlibrary && zlibAccount.isLoggedIn {
                    zlibAccount.downloadsToday += 1
                    persistZLibAccount(zlibAccount)
                }
                await vm.openEPUB(url: url)
            } catch {
                downloadProgress[item.id] = nil
                report("《\(item.title)》下载失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: 微信读书

    @Published var wereadLoggedIn = false
    @Published var wereadLoadingShelf = false
    @Published var wereadShelf: [WeReadShelfService.ShelfBook] = []

    enum WeReadFetchState: Equatable {
        case idle
        case running(status: String, progress: Double)
        case done(message: String)
        case failed(message: String)
    }
    @Published var wereadStates: [String: WeReadFetchState] = [:]

    func activateWeread() {
        activeKind = .weread
        message = nil
        selection = nil
        refreshWereadState()
    }

    func refreshWereadState() {
        wereadLoggedIn = WeReadContentService.shared.hasCookie
        if wereadLoggedIn && wereadShelf.isEmpty {
            loadWereadShelf()
        }
    }

    func loadWereadShelf() {
        guard !wereadLoadingShelf else { return }
        Task {
            wereadLoadingShelf = true
            defer { wereadLoadingShelf = false }
            do {
                wereadShelf = try await WeReadShelfService.shared.fetchShelf()
                wereadLoggedIn = WeReadContentService.shared.hasCookie
            } catch {
                wereadLoggedIn = false
                report((error as? LocalizedError)?.errorDescription ?? "微信读书书架加载失败")
            }
        }
    }

    /// 抓正文 → 组整本 EPUB → 落书架目录（原窗口同一管线，章间限速）。
    func downloadWereadBook(_ book: WeReadShelfService.ShelfBook) {
        if case .running = (wereadStates[book.bookId] ?? .idle) { return }
        wereadStates[book.bookId] = .running(status: "验证目录…", progress: 0)
        Task {
            do {
                let service = WeReadContentService.shared
                let catalog = try await service.previewCatalog(bookId: book.bookId)
                guard !catalog.chapters.isEmpty else {
                    throw WeReadContentService.WeReadContentError.noChapters
                }
                let title = catalog.title.isEmpty ? book.title : catalog.title
                let total = catalog.chapters.count
                let fetched = try await WeReadEPUBAssembler.fetchWholeBook(
                    bookId: book.bookId,
                    chapters: catalog.chapters,
                    onProgress: { [weak self] done, donetotal, chapterTitle in
                        let progress = Double(done) / Double(max(1, donetotal))
                        let status = "抓取 \(done + 1)/\(donetotal) 章"
                        _ = chapterTitle
                        Task { @MainActor [weak self] in
                            self?.wereadStates[book.bookId] = .running(status: status, progress: progress)
                        }
                    }
                )
                wereadStates[book.bookId] = .running(status: "组装 EPUB…", progress: 0.97)
                let fm = FileManager.default
                let shelfDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                    .appendingPathComponent("DReader/DownloadedBooks", isDirectory: true)
                try fm.createDirectory(at: shelfDir, withIntermediateDirectories: true)
                let safeTitle = title.replacingOccurrences(of: "/", with: "_")
                let outputURL = shelfDir.appendingPathComponent("《\(safeTitle)》(微信读书).epub")
                try WeReadEPUBAssembler.packageEPUB(
                    bookId: book.bookId,
                    title: title,
                    author: book.author.isEmpty ? "WeRead" : book.author,
                    chapters: fetched,
                    css: nil,
                    outputURL: outputURL
                )
                wereadStates[book.bookId] = .done(message: "已入架")
                NotificationCenter.default.post(name: .init("DReaderReloadShelf"), object: nil)
                await vm.openEPUB(url: outputURL)
            } catch is CancellationError {
                wereadStates[book.bookId] = .idle
            } catch {
                wereadStates[book.bookId] = .failed(
                    message: "下载失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
            }
        }
    }

    // MARK: 试读

    func previewAction(_ selection: LibrarySelection) {
        switch selection.payload {
        case .opds(let entry, let source):
            guard previewProgress[selection.id] == nil else { return }
            runOPDSPreview(entry: entry, source: source, key: selection.id)
        case .weread(let book):
            guard previewProgress[selection.id] == nil else { return }
            runWereadPreview(book: book, key: selection.id)
        case .publicSearch:
            report("公共书库的书体积不大，直接「下载导入」即可")
        }
    }

    /// OPDS 试读：下载完整本到临时目录 → 解析 → 前 3 章裁剪 → 直接进阅读器。
    private func runOPDSPreview(entry: OPDSService.Entry, source: OPDSService.Source, key: String) {
        previewProgress[key] = 0.01
        previewMessage.removeValue(forKey: key)
        Task {
            do {
                let fm = FileManager.default
                let previewDir = fm.temporaryDirectory
                    .appendingPathComponent("DReaderPreviews", isDirectory: true)
                try fm.createDirectory(at: previewDir, withIntermediateDirectories: true)
                let safeName = entry.title
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: ":", with: "_")
                    .trimmingCharacters(in: .whitespaces)
                let tempURL = previewDir.appendingPathComponent("\(safeName)-\(UUID().uuidString.prefix(6)).epub")
                let url = try await OPDSService.shared.downloadEPUB(
                    entry: entry, source: source, destination: tempURL
                ) { [weak self] progress in
                    Task { @MainActor [weak self] in self?.previewProgress[key] = progress }
                }
                previewProgress[key] = 0.995
                let parsed = try await EPUBParser.shared.parse(fileURL: url)
                let total = parsed.chapters.count
                var sliced = parsed
                sliced.chapters = Array(parsed.chapters.prefix(min(3, total)))
                vm.enterPreview(book: sliced, meta: .opds(fileURL: url), totalChapters: total)
                previewProgress[key] = nil
                previewMessage.removeValue(forKey: key)
            } catch {
                previewProgress[key] = nil
                previewMessage[key] = "《\(entry.title)》试读失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            }
        }
    }

    /// 微信读书试读：首 3 章抓取组装 → 临时 EPUB → 进阅读器。
    private func runWereadPreview(book: WeReadShelfService.ShelfBook, key: String) {
        previewProgress[key] = 0.01
        previewMessage.removeValue(forKey: key)
        Task {
            do {
                let service = WeReadContentService.shared
                let catalog = try await service.previewCatalog(bookId: book.bookId)
                guard !catalog.chapters.isEmpty else {
                    throw WeReadContentService.WeReadContentError.noChapters
                }
                let total = catalog.chapters.count
                let previewChapters = Array(catalog.chapters.prefix(3))
                let fetched = try await WeReadEPUBAssembler.fetchWholeBook(
                    bookId: book.bookId,
                    chapters: previewChapters,
                    onProgress: { [weak self] done, donetotal, chapterTitle in
                        let progress = min(0.9, Double(donetotal) > 0 ? Double(done + 1) / Double(donetotal) * 0.85 + 0.05 : 0.9)
                        let label = chapterTitle.isEmpty ? "" : "（\(chapterTitle)）"
                        let status = "抓取 \(done + 1)/\(previewChapters.count) 章\(label)"
                        Task { @MainActor [weak self] in
                            self?.previewProgress[key] = progress
                            self?.previewMessage[key] = status
                        }
                    }
                )
                previewProgress[key] = 0.92
                previewMessage[key] = "组装试读…"
                let fm = FileManager.default
                let previewDir = fm.temporaryDirectory
                    .appendingPathComponent("DReaderPreviews", isDirectory: true)
                try fm.createDirectory(at: previewDir, withIntermediateDirectories: true)
                let tempURL = previewDir.appendingPathComponent("微信试读-\(book.bookId).epub")
                try WeReadEPUBAssembler.packageEPUB(
                    bookId: book.bookId,
                    title: "\(book.title)（试读）",
                    author: book.author.isEmpty ? "WeRead" : book.author,
                    chapters: fetched,
                    css: nil,
                    outputURL: tempURL
                )
                let parsed = try await EPUBParser.shared.parse(fileURL: tempURL)
                vm.enterPreview(
                    book: parsed,
                    meta: .weread(bookId: book.bookId, title: book.title, author: book.author, cover: book.cover),
                    totalChapters: total
                )
                previewProgress[key] = nil
                previewMessage.removeValue(forKey: key)
            } catch {
                previewProgress[key] = nil
                previewMessage[key] = "《\(book.title)》试读失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            }
        }
    }

    // MARK: 下载调度（详情面板统一按钮）

    func downloadAction(_ selection: LibrarySelection) {
        switch selection.payload {
        case .publicSearch(let item):
            downloadPublic(item)
        case .opds(let entry, _):
            opds.download(entry)
        case .weread(let book):
            downloadWereadBook(book)
        }
    }

    func supportsPreview(_ selection: LibrarySelection) -> Bool {
        switch selection.payload {
        case .opds, .weread: return true
        case .publicSearch: return false
        }
    }

    /// 卡片进度（下载中或试读中）。
    func progressFor(_ selection: LibrarySelection) -> Double? {
        if let p = previewProgress[selection.id] { return p }
        switch selection.payload {
        case .publicSearch(let item):
            return downloadProgress[item.id]
        case .opds(let entry, _):
            return opds.downloading[entry.id]
        case .weread(let book):
            if case .running(_, let progress) = (wereadStates[book.bookId] ?? .idle) {
                return progress
            }
            return nil
        }
    }

    /// 中栏在选了具体源时展示。
    var organizeColumnVisible: Bool {
        activeKind != .none
    }

    var isDrawerOpen: Bool { selection != nil }
}

// MARK: - 三栏视图

struct OnlineLibraryView: View {
    @Bindable var vm: ReaderViewModel
    @StateObject private var model: OnlineLibraryModel
    @Environment(\.colorScheme) private var colorScheme

    init(vm: ReaderViewModel) {
        self.vm = vm
        _model = StateObject(wrappedValue: OnlineLibraryModel(vm: vm))
    }

    var body: some View {
        VStack(spacing: 0) {
            libraryHeader

            if let msg = model.message {
                errorStrip(msg, clear: { model.message = nil })
            }
            if let opdsErr = model.opds.errorMessage {
                errorStrip(opdsErr, clear: { model.opds.errorMessage = nil })
            }

            HStack(spacing: 0) {
                sourceColumn
                    .frame(width: 212)
                Divider().opacity(0.12)
                if model.organizeColumnVisible {
                    organizeColumn
                        .frame(width: 244)
                    Divider().opacity(0.12)
                }
                mediaColumn
            }
        }
        .background(backgroundColor)
        .sheet(isPresented: $model.showZLibLogin) {
            ZLibLoginSheet(model: model)
        }
        .onAppear { model.onAppear() }
        .onReceive(NotificationCenter.default.publisher(for: WeReadContentService.cookieDidChangeNotification)) { _ in
            model.refreshWereadState()
        }
    }

    private var backgroundColor: Color {
        colorScheme == .dark
            ? Color(hex: "#171310")
            : Color(hex: "#F3EDE2")
    }

    private var cardBackground: Color {
        colorScheme == .dark
            ? Color(hex: "#241E19")
            : Color(hex: "#FFFDF8")
    }

    private func errorStrip(_ text: String, clear: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer()
            Button {
                clear()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.12))
    }

    // MARK: 顶部

    private var libraryHeader: some View {
        HStack(spacing: 12) {
            Button {
                vm.returnToBookshelf()
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

            Image(systemName: "globe.americas.fill")
                .font(.system(size: 14))
                .foregroundStyle(Color(hex: "#9E7A45"))
            Text("在线数字书库")
                .font(.system(size: 15, weight: .bold, design: .serif))
                .foregroundStyle(.primary)

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // MARK: 左栏（书源）

    private var sourceColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                sectionLabel("公共书库")
                ForEach([OnlineBookSource.openLibrary, .gutenberg, .zlibrary]) { source in
                    sourceRow(
                        icon: source.icon,
                        iconColor: Color(hex: source.badgeColorHex),
                        name: shortName(source),
                        isActive: model.activeKind == .publicSearch(source),
                        badge: source == .zlibrary ? (model.zlibAccount.isLoggedIn ? "已登录" : "未登录") : nil
                    ) {
                        model.activatePublicSource(source)
                    }
                }

                sectionLabel("OPDS 私人书馆")
                ForEach(model.opds.sources) { source in
                    sourceRow(
                        icon: "server.rack",
                        iconColor: Color(hex: OnlineBookSource.opds.badgeColorHex),
                        name: source.name,
                        isActive: model.activeKind == .opds && model.opds.activeSource?.id == source.id
                    ) {
                        model.openOPDS(source)
                    }
                }
                sourceRow(
                    icon: "plus.circle",
                    iconColor: .secondary.opacity(0.7),
                    name: "接入新书馆",
                    isActive: model.activeKind == .opds && model.opds.activeSource == nil
                ) {
                    model.beginAddOPDSSource()
                }

                sectionLabel("在线平台")
                sourceRow(
                    icon: "book.pages",
                    iconColor: Color(hex: "#1F9E51"),
                    name: "微信读书书架",
                    isActive: model.activeKind == .weread,
                    badge: model.wereadLoggedIn ? "已登录" : "未登录"
                ) {
                    model.activateWeread()
                }
            }
            .padding(14)
        }
        .frame(maxHeight: .infinity)
    }

    private func shortName(_ source: OnlineBookSource) -> String {
        switch source {
        case .openLibrary: return "Open Library"
        case .gutenberg: return "古腾堡计划"
        case .zlibrary: return "Z-Library"
        default: return source.rawValue
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Color.secondary.opacity(0.75))
            .padding(.top, 12)
            .padding(.bottom, 5)
            .padding(.leading, 6)
    }

    private func sourceRow(
        icon: String,
        iconColor: Color,
        name: String,
        isActive: Bool,
        badge: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(iconColor)
                    .frame(width: 20)
                Text(name)
                    .font(.system(size: 12.5, weight: isActive ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.secondary.opacity(0.8))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(isActive ? Color.primary.opacity(0.08) : Color.primary.opacity(0.02))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 中栏

    private var organizeColumn: some View {
        VStack(spacing: 0) {
            switch model.activeKind {
            case .none:
                EmptyView()
            case .publicSearch(let source):
                publicSearchControls(source)
            case .opds:
                if model.opds.mode == .browse && model.opds.activeSource != nil {
                    opdsOrganizeColumn
                } else {
                    opdsManageColumn
                }
            case .weread:
                wereadOrganizeColumn
            }
        }
    }

    private func publicSearchControls(_ source: OnlineBookSource) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("公共书库检索")
                .font(.system(size: 12, weight: .semibold))

            HStack(spacing: 8) {
                TextField("书名 / 作者 / 关键词", text: $model.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                    .onSubmit { model.performSearch() }
                Button {
                    model.performSearch()
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
            }

            Text("快捷推荐")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.secondary.opacity(0.7))
            FlowLayoutChips(items: model.quickChips(for: source)) { chip in
                model.searchQuery = chip
                model.performSearch()
            }

            if source == .zlibrary {
                zlibAccountBar
            }

            Text("这些书库按关键词检索，结果优先取回 EPUB；适合顺路找经典与流行书目。")
                .font(.system(size: 10.5))
                .foregroundStyle(Color.secondary.opacity(0.7))
                .lineLimit(3)
        }
        .padding(14)
    }

    private var zlibAccountBar: some View {
        HStack(spacing: 8) {
            Image(systemName: model.zlibAccount.isLoggedIn ? "checkmark.seal.fill" : "person.crop.circle")
                .font(.system(size: 12))
                .foregroundStyle(model.zlibAccount.isLoggedIn ? Color.green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.zlibAccount.isLoggedIn ? model.zlibAccount.email : "未登录")
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
                Text("今日剩余 \(model.zlibAccount.remainingQuota)/\(model.zlibAccount.dailyLimit) 本")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button {
                model.showZLibLogin = true
            } label: {
                Text(model.zlibAccount.isLoggedIn ? "切换" : "登录")
                    .font(.system(size: 10.5, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.04)))
    }

    // MARK: OPDS 中栏（目录浏览态）

    private var opdsOrganizeColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 面包屑
            HStack(spacing: 4) {
                ForEach(model.opds.stack.indices, id: \.self) { index in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8))
                            .foregroundStyle(Color.secondary.opacity(0.5))
                    }
                    Button {
                        model.opds.popTo(index)
                        model.selection = nil
                    } label: {
                        Text(model.opds.stack[index].title.isEmpty ? "根目录" : model.opds.stack[index].title)
                            .font(.system(size: 10.5, weight: index == model.opds.stack.count - 1 && !model.opds.isSearchResults ? .semibold : .regular))
                            .foregroundStyle(index == model.opds.stack.count - 1 && !model.opds.isSearchResults ? Color.primary.opacity(0.85) : Color.secondary.opacity(0.8))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .buttonStyle(.plain)
                }
                if model.opds.isSearchResults {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                    Text("搜索结果")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.85))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)

            Divider().opacity(0.1)

            // 馆内搜索
            if model.opds.searchTemplate != nil {
                HStack(spacing: 7) {
                    TextField("馆内搜索，回车即搜", text: $model.opds.searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 7))
                        .onSubmit { model.opds.submitSearch() }
                    Button {
                        model.opds.submitSearch()
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    if !model.opds.searchQuery.isEmpty || model.opds.isSearchResults {
                        Button {
                            model.opds.searchQuery = ""
                            model.opds.exitSearch()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                Divider().opacity(0.08)
            }

            // 子目录树（进入下一层的节点）
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    let subsections = model.opds.currentEntries.filter { !$0.isBook }
                    if !subsections.isEmpty {
                        Text("分类目录")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.secondary.opacity(0.7))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                    }
                    ForEach(subsections) { entry in
                        Button {
                            model.opds.openSub(entry)
                            model.selection = nil
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: folderGlyph(entry.title))
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color(hex: OnlineBookSource.opds.badgeColorHex))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.title)
                                        .font(.system(size: 12, weight: .medium))
                                        .lineLimit(1)
                                    if !entry.summary.isEmpty {
                                        Text(entry.summary)
                                            .font(.system(size: 9.5))
                                            .foregroundStyle(Color.secondary.opacity(0.75))
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 2)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Color.secondary.opacity(0.45))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer(minLength: 8)

                    Button {
                        model.opds.back()
                        model.selection = nil
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 10, weight: .semibold))
                            Text("返回上级")
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(Color.secondary.opacity(0.85))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.bottom, 14)
            }
        }
    }

    private func folderGlyph(_ title: String) -> String {
        let lowered = title.lowercased()
        if lowered.contains("榜") || lowered.contains("排行") { return "chart.bar" }
        if lowered.contains("分类") || lowered.contains("目录") { return "folder.grid.2x2" }
        if lowered.contains("最新") || lowered.contains("上架") { return "sparkles" }
        if lowered.contains("推荐") { return "hands.and.sparkles" }
        return "folder"
    }

    // MARK: OPDS 中栏（书馆管理态）

    private var opdsManageColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("你的私人书馆")
                    .font(.system(size: 12, weight: .semibold))

                ForEach(model.opds.sources) { source in
                    opdsManageRow(source)
                }

                if model.opds.sources.isEmpty {
                    Text("还没有接入书馆。支持 Calibre-Web、Kavita、BookOrbit 等任何 OPDS 服务。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.secondary.opacity(0.8))
                        .lineSpacing(2)
                }

                Button {
                    model.opds.beginAdd()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus.circle.fill")
                        Text("添加书馆")
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(Color(hex: OnlineBookSource.opds.badgeColorHex), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)

                if model.opds.showForm {
                    opdsSourceForm
                }
            }
            .padding(14)
        }
    }

    private func opdsManageRow(_ source: OPDSService.Source) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(source.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Button {
                    model.opds.beginEdit(source)
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                Button {
                    model.opds.deleteSource(source)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Text(source.url)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(Color.secondary.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                model.openOPDS(source)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.forward.circle.fill")
                        .font(.system(size: 10))
                    Text("连接浏览")
                        .font(.system(size: 10.5, weight: .semibold))
                }
                .foregroundStyle(Color(hex: OnlineBookSource.opds.badgeColorHex))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color(hex: OnlineBookSource.opds.badgeColorHex).opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.6)
        )
    }

    private var opdsSourceForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.opds.editingID == nil ? "添加 OPDS 书馆" : "编辑书馆")
                    .font(.system(size: 11.5, weight: .bold))
                Spacer()
                Button {
                    model.opds.showForm = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Text("地址")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("http://192.168.1.10:8080/opds", text: $model.opds.formURL)
                .textFieldStyle(.plain)
                .font(.system(size: 10.5, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 7))

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("名称")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    TextField("可留空", text: $model.opds.formName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 10.5))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("用户名")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    TextField("可留空", text: $model.opds.formUsername)
                        .textFieldStyle(.plain)
                        .font(.system(size: 10.5))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("密码")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                SecureField("可选", text: $model.opds.formPassword)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10.5))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            }

            Toggle(isOn: $model.opds.formAllowSelfSigned) {
                Text("接受自签名证书")
                    .font(.system(size: 10))
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Button {
                model.opds.saveForm()
            } label: {
                Text("保存")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(Color(hex: OnlineBookSource.opds.badgeColorHex), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: 微信读书中栏

    private var wereadOrganizeColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("微信读书书架")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if model.wereadLoadingShelf {
                    ProgressView().controlSize(.mini)
                } else if model.wereadLoggedIn {
                    Button {
                        model.loadWereadShelf()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            if model.wereadLoggedIn {
                Text("整本抓取按章限速防封（章间 1.2s）。所有书均可先试读前 3 章。")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.secondary.opacity(0.75))
                    .lineLimit(3)
                    .padding(.horizontal, 14)
            }

            // 笔记同步走 API Key（wrk-*）独立于扫码 cookie，两种凭据任配其一即可用
            Button {
                vm.showWeChatSyncModal = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "quote.bubble.fill")
                        .font(.system(size: 10))
                    Text("同步阅读笔记（API Key）")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .foregroundStyle(Color(hex: "#1F9E51").opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color(hex: "#1F9E51").opacity(0.10), in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .help("绑定 WEREAD_API_KEY 后导入划线与想法 (⌘+⇧+W)")

            if !model.wereadLoggedIn {
                VStack(spacing: 10) {
                    Image(systemName: "person.icloud")
                        .font(.system(size: 26))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                    Text("扫码登录后拉取个人书架")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Button {
                        WeReadQRLoginWindowController.present()
                    } label: {
                        Text("微信扫码登录")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Color.primary.opacity(0.75), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 26)
            }
        }
    }

    // MARK: 右栏（书网格 + 详情抽屉）

    private var mediaColumn: some View {
        HStack(spacing: 0) {
            ZStack {
                if model.isSearching || (model.activeKind == .opds && model.opds.isLoading) || model.wereadLoadingShelf {
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.regular)
                        Text("正在加载…")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                } else if activeBooks.isEmpty {
                    emptyBooksState
                } else {
                    bookGrid
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let selection = model.selection, model.isDrawerOpen {
                Divider().opacity(0.12)
                detailDrawer(selection)
                    .frame(width: 298)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.selection?.id)
    }

    private var emptyBooksState: some View {
        VStack(spacing: 12) {
            Image(systemName: emptyIconName)
                .font(.system(size: 32))
                .foregroundStyle(Color.secondary.opacity(0.4))
            Text(emptyHint)
                .font(.system(size: 12, weight: .medium, design: .serif))
                .foregroundStyle(Color.secondary.opacity(0.75))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyIconName: String {
        switch model.activeKind {
        case .none: return "books.vertical"
        case .publicSearch: return "doc.text.magnifyingglass"
        case .opds: return model.opds.mode == .browse ? "books.vertical" : "servers"
        case .weread: return "book.closed"
        }
    }

    private var emptyHint: String {
        switch model.activeKind {
        case .none:
            return "从左侧选一个书源，开始浏览你的云端图书馆。"
        case .publicSearch:
            return "输入关键词搜索，或点快捷推荐词。"
        case .opds:
            if model.opds.mode == .browse, model.opds.activeSource != nil {
                return "本目录暂无条目。"
            }
            return "添加你的私人 OPDS 书馆，然后就能在云端目录里翻书了。"
        case .weread:
            return "扫码登录后即可浏览个人书架。"
        }
    }

    /// 当前右栏书本条目（跨源统一）。
    private var activeBooks: [LibrarySelection] {
        switch model.activeKind {
        case .none:
            return []
        case .publicSearch:
            return model.searchResults.map { LibrarySelection(payload: .publicSearch($0)) }
        case .opds:
            guard model.opds.mode == .browse, let source = model.opds.activeSource else { return [] }
            let entries = model.opds.currentEntries.filter { $0.isBook }
            return entries.map { LibrarySelection(payload: .opds($0, source)) }
        case .weread:
            return model.wereadShelf.map { LibrarySelection(payload: .weread($0)) }
        }
    }

    private var bookGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 138, maximum: 190), spacing: 14)],
                spacing: 16
            ) {
                ForEach(activeBooks) { selection in
                    bookCard(selection)
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                model.selection = selection
                            }
                        }
                }
            }
            .padding(18)

            loadMoreFooter
        }
    }

    @ViewBuilder
    private var loadMoreFooter: some View {
        if model.activeKind == .opds, model.opds.currentFeed?.nextPageURL != nil {
            HStack {
                Spacer()
                Button {
                    model.opds.loadNextPage()
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
    }

    private func bookCard(_ selection: LibrarySelection) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            selectionsCover(selection)
                .frame(width: 138, height: 192)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 0.6)
                )
                .shadow(color: .black.opacity(0.12), radius: 5, y: 2)

            Text(selection.title)
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(selection.author.isEmpty ? "佚名" : selection.author)
                .font(.system(size: 10))
                .foregroundStyle(Color.secondary.opacity(0.8))
                .lineLimit(1)

            if let progress = model.progressFor(selection) {
                VStack(alignment: .leading, spacing: 3) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(Color(hex: "#9E7A45"))
                    if let message = cardStatusText(selection) {
                        Text(message)
                            .font(.system(size: 9))
                            .foregroundStyle(Color.secondary.opacity(0.8))
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(model.selection?.id == selection.id ? Color.primary.opacity(0.06) : cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    model.selection?.id == selection.id ? Color(hex: "#9E7A45").opacity(0.5) : Color.primary.opacity(0.07),
                    lineWidth: 1
                )
        )
        .contentShape(Rectangle())
    }

    private func cardStatusText(_ selection: LibrarySelection) -> String? {
        // 微信读书卡片显示本地状态文案（running 状态或已完成），其余沿用 previewMessage
        if case .weread(let book) = selection.payload {
            switch model.wereadStates[book.bookId] ?? .idle {
            case .running(let status, _):
                if model.previewProgress[selection.id] != nil { return model.previewMessage[selection.id] }
                return status
            case .done(let message):
                return message
            case .idle:
                return model.previewMessage[selection.id]
            case .failed:
                return nil
            }
        }
        return model.previewMessage[selection.id]
    }

    // MARK: 封面

    @ViewBuilder
    private func selectionsCover(_ selection: LibrarySelection) -> some View {
        switch selection.payload {
        case .publicSearch(let item):
            AsyncImage(url: item.coverURL) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    coverPlaceholder(selection.title)
                }
            }
        case .opds(let entry, let source):
            OPDSCoverImage(href: entry.coverURL, source: source)
        case .weread(let book):
            let highRes = WeReadShelfService.highResCover(book.cover)
            if let url = URL(string: highRes), !highRes.isEmpty {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        coverPlaceholder(book.title)
                    }
                }
            } else {
                coverPlaceholder(book.title)
            }
        }
    }

    private func coverPlaceholder(_ title: String) -> some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: "#B8925F").opacity(0.55), Color(hex: "#7B6144").opacity(0.65)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            Text(String(title.prefix(6)))
                .font(.system(size: 12, weight: .semibold, design: .serif))
                .foregroundStyle(Color.white.opacity(0.9))
                .multilineTextAlignment(.center)
                .padding(8)
        }
    }

    // MARK: 详情抽屉

    private func detailDrawer(_ selection: LibrarySelection) -> some View {
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

            selectionHeader(selection)
                .padding(14)

            if let summary = selectionSummary(selection), !summary.isEmpty {
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

            Divider().opacity(0.1)
            detailActionRow(selection)
                .padding(14)
        }
        .background(backgroundColor)
    }

    private func selectionSummary(_ selection: LibrarySelection) -> String? {
        switch selection.payload {
        case .publicSearch(let item):
            return item.description ?? "自\(item.source.rawValue)，格式 \(item.fileExtension.uppercased())。"
        case .opds(let entry, _):
            return entry.summary.isEmpty ? nil : entry.summary
        case .weread:
            return nil
        }
    }

    private func selectionHeader(_ selection: LibrarySelection) -> some View {
        HStack(alignment: .top, spacing: 12) {
            selectionsCover(selection)
                .frame(width: 84, height: 118)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))

            VStack(alignment: .leading, spacing: 6) {
                Text(selection.title)
                    .font(.system(size: 13, weight: .bold, design: .serif))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(selection.author.isEmpty ? "佚名" : selection.author)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondary.opacity(0.85))
                metadataChips(selection)
            }
        }
    }

    @ViewBuilder
    private func metadataChips(_ selection: LibrarySelection) -> some View {
        switch selection.payload {
        case .publicSearch(let item):
            let chips: [String] = [
                item.fileSizeFormatted.map { "大小 \($0)" },
                item.publishYear.map { "\($0) 年" },
                item.language.map { "语言 \($0)" },
                item.isPublicDomain ? "公有领域" : nil,
            ].compactMap { $0 }
            if !chips.isEmpty {
                FlowLayoutChips(items: chips, onSelect: { _ in })
            }
        case .opds(let entry, _):
            let chips = entry.acquisitionLinks.map { link -> String in
                if link.type.contains("epub") { return "EPUB" }
                if link.type.contains("mobi") { return "MOBI" }
                if link.type.contains("pdf") { return "PDF" }
                return link.type.components(separatedBy: "/").last?.uppercased() ?? "未知格式"
            }
            if !chips.isEmpty {
                FlowLayoutChips(items: chips, onSelect: { _ in })
            }
        case .weread:
            FlowLayoutChips(items: ["微信读书正版"], onSelect: { _ in })
        }
    }

    // MARK: 详情按钮区

    private func detailActionRow(_ selection: LibrarySelection) -> some View {
        VStack(spacing: 8) {
            if let previewErrMsg = model.previewMessage[selection.id],
               model.progressFor(selection) == nil,
               model.previewProgress[selection.id] == nil {
                Text(previewErrMsg)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.red.opacity(0.85))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let progress = model.progressFor(selection) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(model.previewProgress[selection.id] != nil ? "试读准备" : "下载中")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(progress * 100))%")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: progress)
                        .tint(Color(hex: "#9E7A45"))
                    if let msg = cardStatusText(selection) {
                        Text(msg)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.secondary.opacity(0.85))
                            .lineLimit(2)
                    }
                }
            } else if isAlreadyImported(selection) {
                importedBadge
            } else if isNotDownloadable(selection) {
                HStack(spacing: 5) {
                    Image(systemName: "books.vertical")
                        .font(.system(size: 10))
                    Text("仅馆藏目录，无公开电子全本")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
            } else {
                HStack(spacing: 8) {
                    downloadButton(selection)
                    if model.supportsPreview(selection) {
                        previewButton(selection)
                    }
                }
            }
        }
    }

    private func isAlreadyImported(_ selection: LibrarySelection) -> Bool {
        switch selection.payload {
        case .publicSearch(let item):
            return model.downloadedItemIDs.contains(item.id)
        case .opds(let entry, _):
            return model.opds.importedIDs.contains(entry.id)
        case .weread(let book):
            if case .done = (model.wereadStates[book.bookId] ?? .idle) {
                return true
            }
            return false
        }
    }

    private func isNotDownloadable(_ selection: LibrarySelection) -> Bool {
        switch selection.payload {
        case .publicSearch(let item):
            return !item.hasDownloadableContent
        default:
            return false
        }
    }

    private var importedBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
            Text("已入书架")
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(.green)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
    }

    private func downloadButton(_ selection: LibrarySelection) -> some View {
        Button {
            model.downloadAction(selection)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 11, weight: .semibold))
                Text("下载导入")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(Color(hex: "#9E7A45"), in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
    }

    private func previewButton(_ selection: LibrarySelection) -> some View {
        Button {
            model.previewAction(selection)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "text.book.closed")
                    .font(.system(size: 11, weight: .semibold))
                Text("试读")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Color.primary.opacity(0.85))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Z-Library 登录 sheet

private struct ZLibLoginSheet: View {
    @ObservedObject var model: OnlineLibraryModel

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "key.fill")
                    .foregroundStyle(Color.primary.opacity(0.75))
                Text("绑定 Z-Library 账号")
                    .font(.system(size: 14, weight: .bold))
                Spacer()
                Button {
                    model.showZLibLogin = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Text("输入 Z-Library 登录邮箱与个人 rem_token / user_key。绑定后使用个人配额拉取电子书。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineSpacing(2)

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("账号邮箱 (Email)")
                        .font(.system(size: 11, weight: .semibold))
                    TextField("your_account@email.com", text: $model.loginEmailInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("个人 API Token / rem_token")
                        .font(.system(size: 11, weight: .semibold))
                    SecureField("输入个人 Token 或密码", text: $model.loginKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                }
            }

            HStack {
                Button("重置") {
                    model.zlibAccount = ZLibraryUserAccount()
                    model.loginEmailInput = ""
                    model.loginKeyInput = ""
                    model.showZLibLogin = false
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .font(.system(size: 11.5))

                Spacer()

                Button("绑定并登录") {
                    model.loginZLib()
                }
                .buttonStyle(.borderedProminent)
                .font(.system(size: 12, weight: .semibold))
            }
            .padding(.top, 6)
        }
        .padding(20)
        .frame(width: 400)
    }
}

/// 标签流（快捷推荐词 / 元数据小白块）。
struct FlowLayoutChips: View {
    let items: [String]
    let onSelect: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76))], spacing: 6) {
            ForEach(items, id: \.self) { item in
                Button {
                    onSelect(item)
                } label: {
                    Text(item)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(Color.primary.opacity(0.75))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().stroke(Color.primary.opacity(0.09), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - 封面图（带认证的异步加载）

/// OPDS 封面可能需要 Basic 认证，AsyncImage 无能为力——自走 Task + 内存缓存。
struct OPDSCoverImage: View {
    let href: String?
    let source: OPDSService.Source?

    @State private var image: NSImage? = nil

    private struct LoadID: Equatable {
        let href: String?
        let source: OPDSService.Source?
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(LinearGradient(colors: [Color.primary.opacity(0.10), Color.primary.opacity(0.05)], startPoint: .top, endPoint: .bottom))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else if href != nil {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(Color.primary.opacity(0.55))
            }
        }
        .task(id: LoadID(href: href, source: source)) {
            image = nil
            guard let href else { return }
            // .task 在主 actor 上运行；fetchImage 的 async 返回 NSImage? 无法标 Sendable，
            // Swift 6.0 拒绝跨 actor 传递。用返回值不加 await 边界的同步封装查询。
            let loaded = await withCheckedContinuation { (continuation: CheckedContinuation<NSImage?, Never>) in
                Task { @MainActor in
                    continuation.resume(returning: OPDSService.shared.fetchImageCached(href: href, source: source))
                }
            }
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}
