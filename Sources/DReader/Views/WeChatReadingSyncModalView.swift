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
    // 正文导入（非官方 Web 接口）
    @State private var importBookId: String = ""
    @State private var isImporting: Bool = false
    @State private var importStatus: String = ""
    @State private var importProgress: Double = 0
    @State private var importTask: Task<Void, Never>? = nil

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

            // 书籍正文导入（Web 接口）
            bookImportBar

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
        // 扫码登录成功后立即把 Cookie 状态点刷成绿色（Cookie 存取发 cookieDidChangeNotification）
        .onReceive(NotificationCenter.default.publisher(for: WeReadContentService.cookieDidChangeNotification)) { _ in
            cookieStateTick += 1
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

    // MARK: - 书籍正文导入（非官方 Web 接口，个人互操作）

    private var bookImportBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Text("导入书籍正文:")
                    .font(.system(size: 12, weight: .semibold))

                TextField("微信读书 bookId（书籍页网址 weread.qq.com/web/reader/ 后那段）", text: $importBookId)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))

                Button {
                    startImport()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 10, weight: .bold))
                        Text("抓取并加入书架")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4.5)
                    .background(Color.primary.opacity(0.82))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .disabled(importBookId.trimmingCharacters(in: .whitespaces).isEmpty || isImporting)

                if isImporting {
                    Button {
                        importTask?.cancel()
                    } label: {
                        Text("停止")
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }

            Text("首次使用请先登录：点击「扫码登录」，在内嵌浏览器中用微信扫码即可自动获取登录态。抓取为个人互操作用途，逐章限速，只抓你有权限阅读的章节。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                if let ck = cookieHint {
                    HStack(spacing: 5) {
                        Image(systemName: ck.hasKey ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(ck.hasKey ? Color.green : Color.orange)
                        Text(ck.label)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        WeReadQRLoginWindowController.present()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "qrcode")
                                .font(.system(size: 10, weight: .bold))
                            Text("扫码登录")
                                .font(.system(size: 11.5, weight: .medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4.5)
                        .background(Color.primary.opacity(0.82))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)

                    Button {
                        importCookieInput = ck.current
                        showCookieEditor = true
                    } label: {
                        Text("手动粘贴")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.primary.opacity(0.75))
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }

            if isImporting {
                VStack(spacing: 6) {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.65)
                        Text(importStatus)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(importProgress * 100))%")
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.primary.opacity(0.75))
                    }
                    ProgressView(value: importProgress)
                        .tint(Color.primary.opacity(0.65))
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .sheet(isPresented: $showCookieEditor) {
            cookieEditorSheet
        }
    }

    @State private var showCookieEditor: Bool = false
    @State private var importCookieInput: String = ""
    /// Cookie 变更信号量：cookieHint 读取它触发 SwiftUI 重算状态点
    @State private var cookieStateTick: Int = 0

    private var cookieHint: (hasKey: Bool, label: String, current: String)? {
        _ = cookieStateTick // 订阅变更信号：扫码登录成功后状态点立即转绿
        let ck = WeReadContentService.shared.cookie
        let hasKey = !ck.isEmpty
        let label = hasKey
            ? "Cookie 已配置 (\(ck.count) 字符)"
            : "Cookie 未配置 — 点「扫码登录」即可完成网页版登录"
        return (hasKey, label, ck)
    }

    private var cookieEditorSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("手动粘贴 Cookie（兜底）")
                    .font(.system(size: 13, weight: .bold))
                Spacer()
                Button {
                    showCookieEditor = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Text("推荐用「扫码登录」。手动方式：浏览器登录 weread.qq.com → DevTools → Application/存储 → Cookies → 复制整段（须含 wr_vid 与 wr_skey）")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $importCookieInput)
                .font(.system(size: 11, design: .monospaced))
                .frame(minHeight: 130)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
            HStack {
                Button {
                    WeReadContentService.shared.cookie = importCookieInput
                    showCookieEditor = false
                } label: {
                    Text("保存")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.8))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                Spacer()
                if !WeReadContentService.shared.cookie.isEmpty {
                    Button {
                        WeReadContentService.shared.cookie = ""
                        importCookieInput = ""
                    } label: {
                        Text("清除")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(18)
        .frame(width: 520)
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

    // MARK: - 正文导入执行

    private func startImport() {
        let rawId = importBookId.trimmingCharacters(in: .whitespacesAndNewlines)
        // 支持粘贴完整 reader URL（…/web/reader/xxxx）自动提取最后一段
        let bookId: String
        if rawId.contains("/") {
            bookId = rawId.components(separatedBy: "/").last ?? rawId
        } else {
            bookId = rawId
        }
        guard !bookId.isEmpty else { return }
        if !WeReadContentService.shared.hasCookie {
            errorMessage = "尚未登录：请先扫码登录微信读书"
            WeReadQRLoginWindowController.present()
            return
        }

        isImporting = true
        importProgress = 0
        importStatus = "正在验证书籍与目录..."
        errorMessage = nil
        successBannerMessage = nil

        importTask = Task { @MainActor in
            do {
                let service = WeReadContentService.shared
                let catalog = try await service.previewCatalog(bookId: bookId)
                guard !catalog.chapters.isEmpty else {
                    throw WeReadContentService.WeReadContentError.noChapters
                }
                importStatus = "《\(catalog.title)》共 \(catalog.chapters.count) 章，开始逐章抓取..."

                let fetched = try await WeReadEPUBAssembler.fetchWholeBook(
                    bookId: bookId,
                    chapters: catalog.chapters,
                    onProgress: { done, total, chapterTitle in
                        importProgress = Double(done) / Double(max(1, total))
                        importStatus = "抓取中 (\(done + 1)/\(total))：\(chapterTitle)"
                    }
                )

                importStatus = "组装 EPUB..."
                let fm = FileManager.default
                let shelfDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                    .appendingPathComponent("DReader/DownloadedBooks", isDirectory: true)
                try fm.createDirectory(at: shelfDir, withIntermediateDirectories: true)
                let safeTitle = catalog.title.replacingOccurrences(of: "/", with: "_")
                let outputURL = shelfDir.appendingPathComponent("《\(safeTitle)》(微信读书).epub")
                try WeReadEPUBAssembler.packageEPUB(
                    bookId: bookId,
                    title: catalog.title,
                    author: "WeRead",
                    chapters: fetched,
                    css: nil,
                    outputURL: outputURL
                )

                isImporting = false
                importProgress = 1
                successBannerMessage = "《\(catalog.title)》已抓取 \(fetched.count) 章并加入书架！"
                importBookId = ""
            } catch is CancellationError {
                isImporting = false
                importStatus = ""
                errorMessage = "导入已停止"
            } catch {
                isImporting = false
                errorMessage = "导入失败: \(error.localizedDescription)"
            }
        }
    }
}
