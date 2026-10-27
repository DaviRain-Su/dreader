import SwiftUI
import AppKit

/// WeChat Reading Sync & Notebooks Management Modal
/// Integrates with WeChat Reading Agent API Gateway to synchronize highlights, thoughts, and reviews.
struct WeChatReadingSyncModalView: View {
    @Bindable var viewModel: ReaderViewModel
    let onClose: () -> Void

    @State private var wechatService = WeChatReadingService.shared
    @State private var apiKeyInput: String = ""
    @State private var isKeySecure: Bool = true
    @State private var isTestingConnection: Bool = false
    @State private var testResultMessage: String? = nil
    @State private var testSuccess: Bool = false

    @State private var isFetchingNotebooks: Bool = false
    @State private var syncingBookId: String? = nil
    @State private var searchQuery: String = ""
    @State private var filterStatus: NotebookFilterStatus = .all
    @State private var successBannerMessage: String? = nil
    @State private var errorMessage: String? = nil

    enum NotebookFilterStatus: String, CaseIterable, Identifiable {
        case all = "全部"
        case reading = "在读"
        case finished = "已读完"
        var id: String { rawValue }
    }

    private var filteredNotebooks: [WeChatNotebookItem] {
        var list = wechatService.notebooks
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            list = list.filter {
                $0.book.title.localizedCaseInsensitiveContains(q) ||
                $0.book.author.localizedCaseInsensitiveContains(q)
            }
        }
        switch filterStatus {
        case .all:
            return list
        case .reading:
            return list.filter { ($0.markedStatus ?? 0) == 0 }
        case .finished:
            return list.filter { ($0.markedStatus ?? 0) == 1 }
        }
    }

    private var wechatNotesCount: Int {
        viewModel.highlights.filter { $0.isFromWeChatRead }.count
    }

    private func syncedNotesCount(for nb: WeChatNotebookItem) -> Int {
        viewModel.highlights.filter {
            $0.bookTitle == nb.book.title ||
            $0.wechatBookId == nb.bookId
        }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerBar

            Divider()
                .opacity(0.2)

            // Configuration Bar
            apiKeyConfigBar

            Divider()
                .opacity(0.15)

            // Status & Feedback Banners
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
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.12))
            }

            if let success = successBannerMessage {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(success)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.primary)
                    Spacer()

                    Button {
                        onClose()
                        viewModel.showGlobalNotebooksModal = true
                    } label: {
                        HStack(spacing: 4) {
                            Text("立即查看笔记")
                            Image(systemName: "arrow.right")
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(hex: "#059648"))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3.5)
                        .background(Color.white.opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)

                    Button {
                        successBannerMessage = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.green.opacity(0.12))
            }

            // Sync Progress Bar if active
            if wechatService.isSyncing {
                VStack(spacing: 6) {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.65)
                        Text(wechatService.syncStatusMessage)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(wechatService.syncProgress * 100))%")
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color(hex: "#07C160"))
                    }
                    ProgressView(value: wechatService.syncProgress)
                        .tint(Color(hex: "#07C160"))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(hex: "#07C160").opacity(0.06))
            }

            // Main Content: Notebooks Browser
            VStack(spacing: 0) {
                searchAndFilterBar

                if isFetchingNotebooks {
                    VStack(spacing: 12) {
                        Spacer()
                        ProgressView()
                        Text("正在拉取微信读书笔记本概览...")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                } else if wechatService.notebooks.isEmpty {
                    emptyNotebooksView
                } else {
                    notebooksListView
                }
            }
        }
        .frame(minWidth: 700, idealWidth: 780, minHeight: 520, idealHeight: 580)
        .background(.ultraThinMaterial)
        .onAppear {
            apiKeyInput = wechatService.apiKey
            if !wechatService.apiKey.isEmpty && wechatService.notebooks.isEmpty {
                refreshNotebooksList()
            }
        }
    }

    // MARK: - Header Bar
    private var headerBar: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: "#07C160"), Color(hex: "#059648")],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 32, height: 32)

                Image(systemName: "quote.bubble.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("微信读书 · 阅读划线与思考同步")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.primary)

                    Text("官方开放网关 1.0.5")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(hex: "#07C160").opacity(0.12))
                        .foregroundStyle(Color(hex: "#07C160"))
                        .clipShape(Capsule())
                }

                Text("双向连通微信读书划线、章节想法与个人书评，统一沉淀于 DReader 深度知识库")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary.opacity(0.8))
            }
            .buttonStyle(.plain)
            .help("关闭 (Esc)")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: - API Key Configuration Bar
    private var apiKeyConfigBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "key.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(wechatService.apiKey.isEmpty ? Color.secondary : Color(hex: "#07C160"))

                Text("API Key:")
                    .font(.system(size: 12, weight: .semibold))

                if isKeySecure {
                    SecureField("输入 WEREAD_API_KEY (wrk-xxxxxxxx)", text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                } else {
                    TextField("输入 WEREAD_API_KEY (wrk-xxxxxxxx)", text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }

                Button {
                    isKeySecure.toggle()
                } label: {
                    Image(systemName: isKeySecure ? "eye" : "eye.slash")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(isKeySecure ? "显示密钥明文" : "隐藏密钥明文")

                // Save Key Button
                Button {
                    wechatService.saveApiKey(apiKeyInput)
                    testAndSaveConnection()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                        Text("保存并连接")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4.5)
                    .background(Color(hex: "#07C160"))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                // Get Key Guide Button
                Button {
                    if let url = URL(string: "https://weread.qq.com/r/weread-skills") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "safari")
                            .font(.system(size: 10))
                        Text("获取密钥")
                            .font(.system(size: 11.5))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4.5)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .help("打开微信读书官方页面生成您的专属 API Key (绑定个人微信读书账号)")
            }

            // Connection Status & Fast Action Row
            HStack(spacing: 12) {
                if isTestingConnection {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.6)
                        Text("正在验证微信读书连接...")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                } else if let testMsg = testResultMessage {
                    HStack(spacing: 5) {
                        Image(systemName: testSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(testSuccess ? Color.green : Color.red)
                        Text(testMsg)
                            .font(.system(size: 11))
                            .foregroundStyle(testSuccess ? Color.secondary : Color.red)
                    }
                } else if !wechatService.apiKey.isEmpty {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                        Text("已绑定 API Key")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)

                        if let lastSync = wechatService.lastSyncDate {
                            Text("· 上次同步: \(formatDate(lastSync))")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary.opacity(0.8))
                        }
                    }
                }

                Spacer()

                if wechatNotesCount > 0 {
                    Button {
                        onClose()
                        viewModel.showGlobalNotebooksModal = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "highlighter")
                                .font(.system(size: 10))
                            Text("查看已同步笔记 (\(wechatNotesCount))")
                                .font(.system(size: 11.5, weight: .medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.orange.opacity(0.14))
                        .foregroundStyle(Color.orange)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.orange.opacity(0.3), lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                    .help("打开笔记中心查看已同步的微信读书划线与想法")
                }

                // Batch Sync All Notes Button
                Button {
                    performBatchSyncAll()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 10, weight: .bold))
                        Text("全量同步所有书籍笔记")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(
                        LinearGradient(
                            colors: [Color(hex: "#07C160"), Color(hex: "#059648")],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .shadow(color: Color(hex: "#07C160").opacity(0.3), radius: 3, y: 1)
                }
                .buttonStyle(.plain)
                .disabled(wechatService.apiKey.isEmpty || wechatService.isSyncing)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.025))
    }

    // MARK: - Search and Filter Bar
    private var searchAndFilterBar: some View {
        HStack(spacing: 10) {
            // Search field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                TextField("搜索书名或作者...", text: $searchQuery)
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
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            // Filter picker
            Picker("", selection: $filterStatus) {
                ForEach(NotebookFilterStatus.allCases) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 170)

            // Refresh button
            Button {
                refreshNotebooksList()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                    Text("刷新列表")
                        .font(.system(size: 11.5))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4.5)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .disabled(isFetchingNotebooks || wechatService.apiKey.isEmpty)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }

    // MARK: - Empty Notebooks View
    private var emptyNotebooksView: some View {
        VStack(spacing: 14) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color(hex: "#07C160").opacity(0.1))
                    .frame(width: 64, height: 64)

                Image(systemName: "text.badge.plus")
                    .font(.system(size: 28))
                    .foregroundStyle(Color(hex: "#07C160"))
            }

            if wechatService.apiKey.isEmpty {
                Text("尚未配置微信读书 API Key")
                    .font(.system(size: 14, weight: .semibold))
                Text("请在上方填入你的专属 WEREAD_API_KEY，即可实时拉取你在微信读书中的全部划线与笔记。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)

                Button {
                    if let url = URL(string: "https://weread.qq.com/r/weread-skills") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "safari.fill")
                        Text("点击前往获取 API Key")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(Color(hex: "#07C160"))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            } else {
                Text("暂未查询到微信读书笔记")
                    .font(.system(size: 14, weight: .semibold))
                Text("请确认你的微信读书账号中有产生划线或想法，然后点击刷新列表。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Button {
                    refreshNotebooksList()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                        Text("重新拉取")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Notebooks List View
    private var notebooksListView: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(filteredNotebooks) { nb in
                    notebookRowView(nb)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Single Notebook Row
    private func notebookRowView(_ nb: WeChatNotebookItem) -> some View {
        let isBookSyncing = (syncingBookId == nb.bookId)
        let matchingLocalBook = viewModel.books.first { b in
            b.title == nb.book.title ||
            nb.book.title.localizedCaseInsensitiveContains(b.title) ||
            b.title.localizedCaseInsensitiveContains(nb.book.title)
        }

        return HStack(spacing: 14) {
            // Book Cover
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(hex: "#1F2937"))
                    .frame(width: 42, height: 58)
                    .shadow(color: .black.opacity(0.18), radius: 2, y: 1)

                if let coverUrl = nb.book.cover, let url = URL(string: coverUrl) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 42, height: 58)
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        default:
                            fallbackCover(nb)
                        }
                    }
                } else {
                    fallbackCover(nb)
                }
            }

            // Book Details
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(nb.book.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if matchingLocalBook != nil {
                        Text("本地有此书")
                            .font(.system(size: 9.5, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.primary.opacity(0.06))
                            .foregroundStyle(Color.primary.opacity(0.75))
                            .clipShape(Capsule())
                    }
                }

                Text(nb.book.author.isEmpty ? "佚名" : nb.book.author)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                // Stats Pills
                HStack(spacing: 6) {
                    HStack(spacing: 3) {
                        Image(systemName: "highlighter")
                            .font(.system(size: 9))
                        Text("\(nb.noteCount) 划线")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.yellow.opacity(0.15))
                    .foregroundStyle(.orange)
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                    if nb.reviewCount > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "bubble.left.and.bubble.right.fill")
                                .font(.system(size: 9))
                            Text("\(nb.reviewCount) 想法")
                                .font(.system(size: 10.5, weight: .medium))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06))
                        .foregroundStyle(Color.primary.opacity(0.75))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }

                    if let status = nb.markedStatus {
                        Text(status == 1 ? "已读完" : "在读")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }

                    if let progress = nb.readingProgress, progress > 0 {
                        Text("进度 \(Int(progress * 100))%")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary.opacity(0.8))
                    }
                }
            }

            Spacer()

            // Actions
            HStack(spacing: 8) {
                // Open in WeChat Reading Web
                Button {
                    let wereadURL = "https://weread.qq.com/web/reader/\(nb.bookId)"
                    if let url = URL(string: wereadURL) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("在微信读书网页版打开")

                let count = syncedNotesCount(for: nb)
                if count > 0 {
                    Button {
                        onClose()
                        viewModel.showGlobalNotebooksModal = true
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "text.book.closed.fill")
                                .font(.system(size: 9.5))
                            Text("查看笔记 (\(count))")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4.5)
                        .background(Color.primary.opacity(0.06))
                        .foregroundStyle(Color.primary.opacity(0.75))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .help("在笔记回顾中心查看本书的所有划线与想法")
                }

                // Sync Single Book
                Button {
                    syncSingleBook(nb)
                } label: {
                    HStack(spacing: 4) {
                        if isBookSyncing {
                            ProgressView()
                                .scaleEffect(0.6)
                        } else {
                            Image(systemName: "arrow.down.doc.fill")
                                .font(.system(size: 10))
                        }
                        Text(isBookSyncing ? "正在同步..." : "同步此书")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4.5)
                    .background(Color(hex: "#07C160").opacity(0.15))
                    .foregroundStyle(Color(hex: "#059648"))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color(hex: "#07C160").opacity(0.3), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isBookSyncing || wechatService.isSyncing)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }

    private func fallbackCover(_ nb: WeChatNotebookItem) -> some View {
        VStack(spacing: 2) {
            Image(systemName: "book.closed")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.8))
            Text(String(nb.book.title.prefix(2)))
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
        }
    }

    // MARK: - Actions
    private func testAndSaveConnection() {
        isTestingConnection = true
        testResultMessage = nil
        errorMessage = nil

        Task { @MainActor in
            do {
                let (books, notes) = try await wechatService.testConnection(testKey: apiKeyInput)
                isTestingConnection = false
                testSuccess = true
                testResultMessage = "网关连通成功！检测到个人书库 \(books) 本书，共 \(notes) 条笔记。"
                refreshNotebooksList()
            } catch {
                isTestingConnection = false
                testSuccess = false
                testResultMessage = "连接失败: \(error.localizedDescription)"
                errorMessage = error.localizedDescription
            }
        }
    }

    private func refreshNotebooksList() {
        guard !wechatService.apiKey.isEmpty else { return }
        isFetchingNotebooks = true
        errorMessage = nil

        Task { @MainActor in
            do {
                _ = try await wechatService.fetchAllNotebooks()
                isFetchingNotebooks = false
            } catch {
                isFetchingNotebooks = false
                errorMessage = "拉取笔记本失败: \(error.localizedDescription)"
            }
        }
    }

    private func syncSingleBook(_ nb: WeChatNotebookItem) {
        syncingBookId = nb.bookId
        errorMessage = nil
        successBannerMessage = nil

        Task { @MainActor in
            do {
                let beforeCount = viewModel.highlights.count
                let updated = try await wechatService.syncSingleBook(
                    notebook: nb,
                    localBooks: viewModel.books,
                    currentHighlights: viewModel.highlights
                )
                viewModel.highlights = updated
                viewModel.persistHighlightsDirectly()
                syncingBookId = nil

                let delta = viewModel.highlights.count - beforeCount
                successBannerMessage = "已成功同步《\(nb.book.title)》的 \(nb.totalNotes) 条划线与想法 (新增 \(max(0, delta)) 条)！"
            } catch {
                syncingBookId = nil
                errorMessage = "同步《\(nb.book.title)》失败: \(error.localizedDescription)"
            }
        }
    }

    private func performBatchSyncAll() {
        errorMessage = nil
        successBannerMessage = nil

        Task { @MainActor in
            do {
                let (imported, updated) = try await wechatService.syncAllNotebooks(
                    localBooks: viewModel.books,
                    currentHighlights: viewModel.highlights
                )
                viewModel.highlights = updated
                viewModel.persistHighlightsDirectly()

                successBannerMessage = "全量同步完成！本次新增导入 \(imported) 条划线与个人思考，已自动存入 DReader 知识库。"
            } catch {
                errorMessage = "全量同步失败: \(error.localizedDescription)"
            }
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
