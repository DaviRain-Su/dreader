import SwiftUI
import AppKit

// MARK: - OPDS 浏览状态机

/// OPDS 标签页的全部状态：书馆管理（表单/列表）与目录浏览（面包屑/网格/搜索/下载）。
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
    @Published var errorMessage: String? = nil
    /// entryID → 下载进度（0...1），nil 即未在下载
    @Published var downloading: [String: Double] = [:]
    @Published var importedIDs: Set<String> = []

    var currentFeed: OPDSService.Feed? {
        isSearchResults ? searchFeed : stack.last
    }

    var currentEntries: [OPDSService.Entry] { currentFeed?.entries ?? [] }

    func onAppear() {
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

// MARK: - OPDS 浏览面板

struct OPDSBrowsePanel: View {
    let onImport: (URL) -> Void
    @StateObject private var model: OPDSBrowseModel

    init(onImport: @escaping (URL) -> Void) {
        self.onImport = onImport
        _model = StateObject(wrappedValue: OPDSBrowseModel(onImport: onImport))
    }

    private var teal: Color { Color(hex: OnlineBookSource.opds.badgeColorHex) }

    var body: some View {
        VStack(spacing: 0) {
            if model.mode == .manage {
                manageView
            } else {
                browseView
            }

            if let err = model.errorMessage {
                errorStrip(err)
            }
        }
        .onAppear { model.onAppear() }
    }

    private func errorStrip(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.primary)
            Spacer()
            Button {
                model.errorMessage = nil
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

    // MARK: 书馆管理

    private var manageView: some View {
        ScrollView {
            VStack(spacing: 12) {
                if model.sources.isEmpty && !model.showForm {
                    emptyCollectionHint
                } else {
                    ForEach(model.sources) { source in
                        sourceRow(source)
                    }
                }
                if model.showForm {
                    sourceForm
                        .transition(.opacity)
                }
            }
            .padding(20)
        }
    }

    private var emptyCollectionHint: some View {
        VStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.system(size: 34))
                .foregroundStyle(.secondary.opacity(0.55))
                .padding(.bottom, 2)
            Text("接入你的私人图书馆")
                .font(.system(size: 16, weight: .bold, design: .serif))
            Text("连接任意 OPDS 服务——自建的 BookOrbit、Calibre-Web、Kavita 均可。在这里直接翻阅云端目录，选中即拉回本地书架。")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
            Text("地址通常形如 http://192.168.1.10:8080/opds")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary.opacity(0.7))
            Button {
                model.beginAdd()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                    Text("添加第一个书馆")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(teal)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 46)
        .padding(.bottom, 24)
    }

    private func sourceRow(_ source: OPDSService.Source) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(teal.opacity(0.14))
                    .frame(width: 34, height: 34)
                Text(String(source.name.prefix(1)))
                    .font(.system(size: 14, weight: .semibold, design: .serif))
                    .foregroundStyle(teal)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(source.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(source.url)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            HStack(spacing: 5) {
                if !source.username.isEmpty {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .help("该源使用账号认证")
                }
                if source.allowSelfSigned {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .help("已接受该源的自签名证书")
                }
            }

            Button {
                model.connect(source)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.forward.circle.fill")
                    Text("连接")
                }
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(teal)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Button {
                model.beginEdit(source)
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("编辑")

            Button {
                model.deleteSource(source)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("删除")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 0.6)
        )
    }

    private var sourceForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(model.editingID == nil ? "添加 OPDS 书馆" : "编辑书馆")
                    .font(.system(size: 13, weight: .bold))
                Spacer()
                Button {
                    model.showForm = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("地址（必填）")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("http://192.168.1.10:8080/opds", text: $model.formURL)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("书馆名称")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    TextField("可留空，默认用域名", text: $model.formName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("用户名")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    TextField("无认证可留空", text: $model.formUsername)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("密码")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    SecureField("可选", text: $model.formPassword)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }

            Toggle(isOn: $model.formAllowSelfSigned) {
                Text("接受自签名证书（自建 NAS / 内网服务常见）")
                    .font(.system(size: 11.5))
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            HStack {
                Text("地址须指向 OPDS 目录根（Calibre-Web 常为 /opds，Kavita 常为 /api/opds）")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary.opacity(0.7))
                Spacer()
                Button {
                    model.saveForm()
                } label: {
                    Text("保存")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(teal)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 0.6)
        )
    }

    // MARK: 目录浏览

    private var browseView: some View {
        VStack(spacing: 0) {
            browseHeader
            Divider().opacity(0.15)
            browseContent
        }
    }

    private var browseHeader: some View {
        HStack(spacing: 12) {
            Button {
                model.back()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("书馆列表")
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Divider()
                .frame(height: 16)
                .opacity(0.3)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(teal)
                    Text(model.activeSource?.name ?? "OPDS")
                        .font(.system(size: 12.5, weight: .bold))
                        .lineLimit(1)
                }
                breadcrumb
            }

            Spacer()

            if model.searchTemplate != nil {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField("馆内搜索，回车即搜", text: $model.searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5))
                        .frame(width: 170)
                        .onSubmit { model.submitSearch() }
                    if !model.searchQuery.isEmpty || model.isSearchResults {
                        Button {
                            model.searchQuery = ""
                            model.exitSearch()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("退出搜索结果")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var breadcrumb: some View {
        HStack(spacing: 3) {
            ForEach(model.stack.indices, id: \.self) { index in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7))
                        .foregroundStyle(.secondary.opacity(0.6))
                }
                Button {
                    model.popTo(index)
                } label: {
                    let isTip = (index == model.stack.count - 1 && !model.isSearchResults)
                    Text(model.stack[index].title.isEmpty ? "首页" : model.stack[index].title)
                        .font(.system(size: 10.5, weight: isTip ? .semibold : .regular))
                        .foregroundStyle(isTip ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 160, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            if model.isSearchResults {
                Image(systemName: "chevron.right")
                    .font(.system(size: 7))
                    .foregroundStyle(.secondary.opacity(0.6))
                Text("搜索结果")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.primary)
            }
            Spacer(minLength: 0)
        }
    }

    private var browseContent: some View {
        ZStack {
            if model.isLoading && model.currentEntries.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.large)
                    Text("正在从「\(model.activeSource?.name ?? "OPDS")」拉取目录…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } else if let feed = model.currentFeed {
                catalogGrid(feed)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "books.vertical")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary.opacity(0.5))
                    Text("这个目录暂时是空的")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func catalogGrid(_ feed: OPDSService.Feed) -> some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 112, maximum: 140), spacing: 12)],
                spacing: 14
            ) {
                let folders = feed.entries.filter { !$0.isBook }
                let books = feed.entries.filter { $0.isBook }
                ForEach(folders) { entry in
                    folderCard(entry)
                }
                ForEach(books) { entry in
                    bookCard(entry)
                }
            }
            .padding(18)

            if feed.nextPageURL != nil {
                HStack {
                    Spacer()
                    if model.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button {
                            model.loadNextPage()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.down.circle")
                                Text("加载更多")
                            }
                            .font(.system(size: 11.5, weight: .medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Color.primary.opacity(0.07))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding(.bottom, 18)
            }
        }
    }

    private func folderCard(_ entry: OPDSService.Entry) -> some View {
        Button {
            model.openSub(entry)
        } label: {
            VStack(spacing: 9) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(teal.opacity(0.75))
                Text(entry.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .padding(.horizontal, 10)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(entry.summary)
    }

    private func bookCard(_ entry: OPDSService.Entry) -> some View {
        VStack(spacing: 7) {
            OPDSCoverImage(href: entry.coverURL, source: model.activeSource)
                .frame(width: 92, height: 128)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 3, x: 0, y: 1.5)

            Text(entry.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(entry.author)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            downloadFooter(entry)
        }
        .padding(10)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 0.5)
        )
        .help(entry.summary)
    }

    @ViewBuilder
    private func downloadFooter(_ entry: OPDSService.Entry) -> some View {
        if model.importedIDs.contains(entry.id) {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                Text("已入书架")
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.green)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let progress = model.downloading[entry.id] {
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(teal)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Button {
                model.download(entry)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle.fill")
                    Text("拉回书架")
                }
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4.5)
                .background(teal)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
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
            } else {
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(Color.primary.opacity(0.55))
            }
        }
        .task(id: LoadID(href: href, source: source)) {
            image = nil
            guard let href else { return }
            let loaded = await OPDSService.shared.fetchImage(href: href, source: source)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}
