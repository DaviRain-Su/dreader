import SwiftUI
import AppKit

/// Online Book Hub Modal View: Open Library, Gutenberg, and Z-Library direct downloads
struct OnlineBookHubModalView: View {
    let onBookDownloadedAndImport: (URL) -> Void
    let onClose: () -> Void

    @State private var selectedSource: OnlineBookSource = .openLibrary
    @State private var searchQuery: String = "Pride and Prejudice"
    @State private var searchResults: [OnlineBookItem] = []
    @State private var isSearching: Bool = false
    @State private var downloadingItemIDs: Set<String> = []
    @State private var downloadedItemIDs: Set<String> = []
    @State private var downloadProgress: [String: Double] = [:]
    @State private var errorMessage: String? = nil

    // Z-Library Account State
    @State private var zlibAccount: ZLibraryUserAccount = ZLibraryUserAccount()
    @State private var showZLibLoginSheet: Bool = false
    @State private var loginEmailInput: String = ""
    @State private var loginKeyInput: String = ""

    private let quickChipsOpenLibrary = ["红楼梦", "道德经", "Pride and Prejudice", "Walden", "鲁迅"]
    private let quickChipsGutenberg = ["红楼梦", "道德经", "三国演义", "西游记", "水浒传", "论语", "孙子兵法", "唐诗三百首"]
    private let quickChipsZLibrary = ["纳瓦尔宝典", "原则", "置身事内", "思考，快与慢", "计算机系统"]

    var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            headerBar

            Divider()
                .opacity(0.2)

            // Source Switcher & Z-Library Account Bar
            VStack(spacing: 0) {
                sourceSwitcherBar

                if selectedSource == .zlibrary {
                    zlibraryStatusBar
                }

                searchAndFilterBar

                if let err = errorMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(err)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.primary)
                        Spacer()
                        Button {
                            errorMessage = nil
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
            }

            Divider()
                .opacity(0.15)

            // Content Area: Search Results or States
            ZStack {
                if isSearching {
                    searchingStateView
                } else if searchResults.isEmpty {
                    emptyResultsView
                } else {
                    resultsListView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 640, idealWidth: 720, maxWidth: 840, minHeight: 520, idealHeight: 620, maxHeight: 720)
        .background(.ultraThinMaterial)
        .sheet(isPresented: $showZLibLoginSheet) {
            zlibLoginSheet
        }
        .onAppear {
            loadPersistedZLibAccount()
            performSearch()
        }
    }

    // MARK: - Header Bar
    private var headerBar: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 30, height: 30)

                Image(systemName: "globe.americas.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("在线数字书库探索中心")
                        .font(.system(size: 14, weight: .bold))

                    Text("Online Book Hub")
                        .font(.system(size: 10.5, design: .serif))
                        .foregroundStyle(.secondary)
                }

                Text("集成 Open Library 公开馆藏、古腾堡计划与 Z-Library 账号直连拉取")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("关闭 (Esc)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Source Switcher
    private var sourceSwitcherBar: some View {
        HStack(spacing: 8) {
            ForEach(OnlineBookSource.allCases) { source in
                let isSelected = (selectedSource == source)
                Button {
                    selectedSource = source
                    if source == .zlibrary && (searchQuery.contains("Pride") || searchQuery.contains("Walden")) {
                        searchQuery = "纳瓦尔宝典"
                    } else if source == .openLibrary && searchQuery.contains("纳瓦尔") {
                        searchQuery = "Pride and Prejudice"
                    }
                    performSearch()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: source.icon)
                            .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? Color(hex: source.badgeColorHex) : .secondary)

                        Text(source.rawValue)
                            .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))

                        if source.requiresLogin {
                            Text(zlibAccount.isLoggedIn ? "已登录" : "需登录")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(zlibAccount.isLoggedIn ? Color.green : Color.orange)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background((zlibAccount.isLoggedIn ? Color.green : Color.orange).opacity(0.12))
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isSelected ? Color(hex: source.badgeColorHex).opacity(0.12) : Color.primary.opacity(0.03))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(isSelected ? Color(hex: source.badgeColorHex).opacity(0.3) : Color.clear, lineWidth: 0.8)
                    )
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.02))
    }

    // MARK: - Z-Library Status Bar
    private var zlibraryStatusBar: some View {
        HStack(spacing: 10) {
            if zlibAccount.isLoggedIn {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                    Text("Z-Library 账号：\(zlibAccount.email)")
                        .font(.system(size: 11, weight: .medium))
                    Text("· 今日剩余下载配额: \(zlibAccount.remainingQuota) / \(zlibAccount.dailyLimit) 本")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.purple)
                }

                Spacer()

                Button("切换账号") {
                    showZLibLoginSheet = true
                }
                .font(.system(size: 10.5))
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                    Text("当前处于预览模式。登录 Z-Library 账号即可解除每日下载限制并直连个人书库。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    showZLibLoginSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "key.fill")
                            .font(.system(size: 9))
                        Text("登录账号 / 绑定 Token")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.purple)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.purple.opacity(0.06))
    }

    // MARK: - Search & Filter Bar
    private var searchAndFilterBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // Search Input Field
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    TextField("搜索书名、作者、ISBN 或关键词（回车即搜）...", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .onSubmit {
                            performSearch()
                        }

                    if !searchQuery.isEmpty {
                        Button {
                            searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                // Search Button
                Button {
                    performSearch()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.right.circle.fill")
                        Text("搜索")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6.5)
                    .background(Color.primary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            // Quick Chips
            HStack(spacing: 6) {
                Text("快捷推荐:")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                let chips: [String] = {
                    switch selectedSource {
                    case .openLibrary: return quickChipsOpenLibrary
                    case .gutenberg: return quickChipsGutenberg
                    case .zlibrary: return quickChipsZLibrary
                    }
                }()
                ForEach(chips, id: \.self) { chip in
                    Button {
                        searchQuery = chip
                        performSearch()
                    } label: {
                        Text(chip)
                            .font(.system(size: 10))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(Color.primary.opacity(0.04))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Results List View
    private var resultsListView: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(searchResults) { book in
                    bookResultCard(book)
                }
            }
            .padding(16)
        }
    }

    // MARK: - Book Result Card
    private func bookResultCard(_ book: OnlineBookItem) -> some View {
        HStack(alignment: .top, spacing: 14) {
            // Book Cover Thumbnail
            AsyncImage(url: book.coverURL) { phase in
                switch phase {
                case .empty:
                    ZStack {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                        ProgressView().controlSize(.small)
                    }
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                case .failure:
                    ZStack {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(LinearGradient(colors: [Color.purple.opacity(0.2), Color.indigo.opacity(0.1)], startPoint: .top, endPoint: .bottom))
                        Image(systemName: "book.closed.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.purple.opacity(0.8))
                    }
                @unknown default:
                    EmptyView()
                }
            }
            .frame(width: 48, height: 68)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 3, x: 0, y: 1.5)

            // Book Information
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(book.title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)

                    Text(book.source.rawValue)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color(hex: book.source.badgeColorHex))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color(hex: book.source.badgeColorHex).opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }

                Text(book.author)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text("格式: \(book.fileExtension.uppercased())")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)

                    if let sz = book.fileSizeFormatted {
                        Text("· 大小: \(sz)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    if let year = book.publishYear {
                        Text("· 出版: \(year)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }

                if let desc = book.description {
                    Text(desc)
                        .font(.system(size: 10.5, design: .serif))
                        .foregroundStyle(.secondary.opacity(0.9))
                        .lineLimit(2)
                        .padding(.top, 1)
                }
            }

            Spacer()

            // Download Action Button
            VStack {
                Spacer()

                let isDownloading = downloadingItemIDs.contains(book.id)
                let isDownloaded = downloadedItemIDs.contains(book.id)

                if isDownloaded {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("已放入书架")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.green.opacity(0.12))
                    .clipShape(Capsule())
                } else if isDownloading {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在拉取...")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.purple.opacity(0.1))
                    .clipShape(Capsule())
                } else if !book.hasDownloadableContent {
                    VStack(spacing: 3) {
                        HStack(spacing: 4) {
                            Image(systemName: "books.vertical")
                                .font(.system(size: 10))
                            Text("仅馆藏目录")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(Capsule())

                        Text("无公开电子全本")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary.opacity(0.7))
                    }
                } else {
                    Button {
                        startDownload(book)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.down.circle.fill")
                            Text("下载并放入书架")
                        }
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6.5)
                        .background(Color(hex: book.source.badgeColorHex))
                        .clipShape(Capsule())
                        .shadow(color: Color(hex: book.source.badgeColorHex).opacity(0.3), radius: 3, y: 1)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.6)
        )
    }

    // MARK: - State Views
    private var searchingStateView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("正在从 \(selectedSource.rawValue) 检索馆藏书目...")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
        }
    }

    private var emptyResultsView: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 32))
                .foregroundStyle(.secondary.opacity(0.7))
            Text("未找到相关书籍")
                .font(.system(size: 13, weight: .medium))
            Text("请尝试更换关键词（例如输入英译书名、作者或简短词汇）")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Z-Library Login Sheet
    private var zlibLoginSheet: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "key.fill")
                    .foregroundStyle(.purple)
                Text("绑定 Z-Library 账号")
                    .font(.system(size: 14, weight: .bold))
                Spacer()
                Button {
                    showZLibLoginSheet = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Text("输入您的 Z-Library 登录邮箱，或在官网个人中心获取的 rem_token / user_key。绑定后即可直接使用个人配额拉取数百万册电子书。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineSpacing(2)

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("账号邮箱 (Email)")
                        .font(.system(size: 11, weight: .semibold))
                    TextField("例如: your_account@email.com", text: $loginEmailInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("个人 API Token / rem_token")
                        .font(.system(size: 11, weight: .semibold))
                    SecureField("输入个人 Token 或密码", text: $loginKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                }
            }

            HStack {
                Button("重置") {
                    zlibAccount = ZLibraryUserAccount()
                    savePersistedZLibAccount()
                    showZLibLoginSheet = false
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .font(.system(size: 11.5))

                Spacer()

                Button("完成绑定并登录") {
                    Task {
                        let acc = await OnlineBookService.shared.loginZLibrary(
                            email: loginEmailInput,
                            userKey: loginKeyInput
                        )
                        self.zlibAccount = acc
                        savePersistedZLibAccount()
                        showZLibLoginSheet = false
                        performSearch()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .font(.system(size: 12, weight: .semibold))
            }
            .padding(.top, 6)
        }
        .padding(20)
        .frame(width: 400)
    }

    // MARK: - Search & Download Execution

    private func performSearch() {
        isSearching = true
        searchResults = []

        Task {
            let results = await OnlineBookService.shared.search(
                query: searchQuery,
                source: selectedSource,
                zlibraryAccount: zlibAccount
            )
            await MainActor.run {
                self.searchResults = results
                self.isSearching = false
            }
        }
    }

    private func startDownload(_ book: OnlineBookItem) {
        downloadingItemIDs.insert(book.id)

        Task {
            do {
                let localURL = try await OnlineBookService.shared.downloadEPUB(item: book)

                await MainActor.run {
                    downloadingItemIDs.remove(book.id)
                    downloadedItemIDs.insert(book.id)
                    // If Z-Library, update daily quota count
                    if book.source == .zlibrary && zlibAccount.isLoggedIn {
                        zlibAccount.downloadsToday += 1
                        savePersistedZLibAccount()
                    }
                    // Automatically import into bookshelf and read!
                    onBookDownloadedAndImport(localURL)
                }
            } catch {
                await MainActor.run {
                    downloadingItemIDs.remove(book.id)
                    self.errorMessage = "下载失败: \(error.localizedDescription)"
                }
            }
        }
    }

    private func savePersistedZLibAccount() {
        if let data = try? JSONEncoder().encode(zlibAccount) {
            UserDefaults.standard.set(data, forKey: "dreader.zlib_account")
        }
    }

    private func loadPersistedZLibAccount() {
        if let data = UserDefaults.standard.data(forKey: "dreader.zlib_account"),
           let decoded = try? JSONDecoder().decode(ZLibraryUserAccount.self, from: data) {
            self.zlibAccount = decoded
            self.loginEmailInput = decoded.email
            self.loginKeyInput = decoded.userKey
        }
    }
}
