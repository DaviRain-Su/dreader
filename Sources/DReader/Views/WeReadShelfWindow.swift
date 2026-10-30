import AppKit
import SwiftUI

/// 微信读书云端书架独立窗口：登录后拉全量书架，封面网格浏览，
/// 每本可「下载入架」抓正文组 EPUB 进 DReader 主书架。
@MainActor
enum WeReadShelfWindowController {
    private static var window: NSWindow?

    static func present() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "微信读书 · 云端书架"
        win.minSize = NSSize(width: 640, height: 480)
        win.contentView = NSHostingView(rootView: WeReadShelfView())
        win.center()
        win.isReleasedWhenClosed = false
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// 单本下载状态（窗口级共享，网格卡片据此渲染按钮/进度）
@MainActor
final class WeReadShelfDownloadTracker: ObservableObject {
    static let shared = WeReadShelfDownloadTracker()

    enum State: Equatable {
        case idle
        case running(status: String, progress: Double)
        case done(message: String)
        case failed(message: String)
    }

    @Published var states: [String: State] = [:]

    func state(for bookId: String) -> State { states[bookId] ?? .idle }

    func set(_ bookId: String, _ state: State) { states[bookId] = state }
}

struct WeReadShelfView: View {
    @State private var books: [WeReadShelfService.ShelfBook] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var searchQuery = ""
    @StateObject private var tracker = WeReadShelfDownloadTracker.shared

    private var filtered: [WeReadShelfService.ShelfBook] {
        let q = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return books }
        return books.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.author.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            if isLoading && books.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(0.9)
                    Text("正在拉取云端书架…")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else if let err = loadError, books.isEmpty {
                Spacer()
                VStack(spacing: 14) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary.opacity(0.6))
                    Text(err)
                        .font(.system(size: 12.5))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 360)
                    if err.contains("登录") {
                        Button {
                            WeReadQRLoginWindowController.present()
                        } label: {
                            Text("扫码登录")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 7)
                                .background(Color.primary.opacity(0.8))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    Button {
                        Task { await load() }
                    } label: {
                        Text("重试")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.primary.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            } else if filtered.isEmpty {
                Spacer()
                Text(searchQuery.isEmpty ? "书架是空的" : "没有匹配「\(searchQuery)」的书")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 20)], spacing: 24) {
                        ForEach(filtered) { book in
                            WeReadShelfCard(book: book)
                        }
                    }
                    .padding(24)
                }
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .onAppear {
            if books.isEmpty && !isLoading {
                Task { await load() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: WeReadContentService.cookieDidChangeNotification)) { _ in
            // 扫码成功后自动重拉书架
            Task { await load() }
        }
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Text("微信读书书架")
                .font(.system(size: 14, weight: .bold))
            if !books.isEmpty {
                Text("\(books.count) 本")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("搜索书名或作者…", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(width: 180)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Button {
                Task { await load() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.75))
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
    }

    private func load() async {
        isLoading = true
        loadError = nil
        do {
            books = try await WeReadShelfService.shared.fetchShelf()
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }
}

/// 封面卡片：封面图 + 书名 + 作者 + 下载入架按钮/进度
private struct WeReadShelfCard: View {
    let book: WeReadShelfService.ShelfBook
    @State private var coverImage: NSImage?
    @ObservedObject private var tracker = WeReadShelfDownloadTracker.shared

    private var state: WeReadShelfDownloadTracker.State {
        tracker.state(for: book.bookId)
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.06))
                if let img = coverImage {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 150, height: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .shadow(color: .black.opacity(0.18), radius: 5, y: 3)
                } else {
                    Image(systemName: "book.closed")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary.opacity(0.5))
                }
            }
            .frame(width: 150, height: 200)

            VStack(spacing: 3) {
                Text(book.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(height: 32, alignment: .top)
                if !book.author.isEmpty {
                    Text(book.author)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            actionFooter
        }
        .frame(width: 158)
        .onAppear { loadCover() }
    }

    @ViewBuilder
    private var actionFooter: some View {
        switch state {
        case .idle:
            Button {
                Task { await downloadToShelf() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 9.5, weight: .bold))
                    Text("下载入架")
                        .font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4.5)
                .background(Color.primary.opacity(0.82))
                .foregroundStyle(.white)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

        case .running(let status, let progress):
            VStack(spacing: 5) {
                ProgressView(value: progress)
                    .tint(Color.primary.opacity(0.65))
                    .frame(width: 130)
                Text(status)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(height: 26)

        case .done(let message):
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.green)
                Text(message)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.8))
            }
            .frame(height: 26)

        case .failed(let message):
            VStack(spacing: 3) {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Button {
                    Task { await downloadToShelf() }
                } label: {
                    Text("重试")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.75))
                }
                .buttonStyle(.plain)
            }
            .frame(height: 34)
        }
    }

    private func loadCover() {
        let urlStr = WeReadShelfService.highResCover(book.cover)
        guard !urlStr.isEmpty, coverImage == nil else { return }
        guard let url = URL(string: urlStr) else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let img = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                coverImage = img
            }
        }.resume()
    }

    /// 抓正文 → 组 EPUB → 主书架（与手动 bookId 导入同一管线，章间限速）
    private func downloadToShelf() async {
        let tracker = self.tracker
        let bookId = book.bookId
        @Sendable func reportProgress(_ done: Int, _ total: Int) {
            let progress = Double(done) / Double(max(1, total))
            MainActor.assumeIsolated {
                tracker.set(bookId, .running(status: "抓取 \(done + 1)/\(total) 章", progress: progress))
            }
        }
        tracker.set(book.bookId, .running(status: "验证目录…", progress: 0))
        do {
            let service = WeReadContentService.shared
            let catalog = try await service.previewCatalog(bookId: book.bookId)
            guard !catalog.chapters.isEmpty else {
                throw WeReadContentService.WeReadContentError.noChapters
            }
            let title = catalog.title.isEmpty ? book.title : catalog.title
            let fetched = try await WeReadEPUBAssembler.fetchWholeBook(
                bookId: book.bookId,
                chapters: catalog.chapters,
                onProgress: { done, total, chapterTitle in
                    reportProgress(done, total)
                    _ = chapterTitle
                }
            )
            tracker.set(book.bookId, .running(status: "组装 EPUB…", progress: 0.97))
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
            tracker.set(book.bookId, .done(message: "已入架"))
            // 通知主窗口书架重载（DReaderReloadShelf 由 ReaderViewModel 监听；若无此通知则下次启动可见）
            NotificationCenter.default.post(name: .init("DReaderReloadShelf"), object: nil)
        } catch is CancellationError {
            tracker.set(book.bookId, .idle)
        } catch {
            tracker.set(book.bookId, .failed(message: "下载失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"))
        }
    }
}
