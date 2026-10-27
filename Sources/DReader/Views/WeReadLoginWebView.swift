import AppKit
import SwiftUI
import WebKit

/// 独立浮动窗口承载扫码登录：尺寸不受主窗口/sheet 约束，
/// 大屏完整展示 weread 网页版二维码。
@MainActor
enum WeReadLoginWindowController {
    private static var window: NSWindow?

    static func present() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let content = WeReadLoginWindowContent(onClose: { close() })
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 740),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "微信读书 · 扫码登录"
        win.minSize = NSSize(width: 620, height: 500)
        win.contentView = NSHostingView(rootView: content)
        win.center()
        win.isReleasedWhenClosed = false
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func close() {
        window?.close()
        window = nil
    }
}

/// 窗口内容：顶部指引 + 完整网页 + 登录成功横幅，成功后自动关闭窗口
private struct WeReadLoginWindowContent: View {
    var onClose: () -> Void
    @State private var succeeded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "qrcode")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
                Text("用微信扫码登录；若页面未出现二维码，点击页面右上角「登录」。登录成功后自动保存并关闭。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Spacer()
                if succeeded {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.green)
                        Text("登录成功，Cookie 已保存")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)

            Divider()

            WeReadLoginWebView { _ in
                guard !succeeded else { return }
                succeeded = true
                Task { @MainActor in
                    // 停留片刻让用户看到成功提示，再自动收窗
                    try? await Task.sleep(nanoseconds: 1_600_000_000)
                    guard !Task.isCancelled else { return }
                    onClose()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 620, minHeight: 500)
    }
}

/// 微信读书内嵌扫码登录：WKWebView 打开网页版，用户扫码登录后自动从
/// WKHTTPCookieStore 抓取 wr_skey/wr_vid 等 Cookie 存入 WeReadContentService。
/// （httponly 的 wr_skey 在 DevTools 复制不便，内嵌浏览器 + cookie store 是最顺的入口。）
struct WeReadLoginWebView: NSViewRepresentable {
    /// 检测到登录态时的回调（携带整段 Cookie header 字符串）
    let onSuccess: (String) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // 复用系统默认数据仓库：已有登录态时无需重复扫码
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.attach(webView)
        if let url = URL(string: "https://weread.qq.com/web") {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onSuccess: onSuccess)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let onSuccess: (String) -> Void
        private var webView: WKWebView?
        private nonisolated(unsafe) var pollTimer: Timer?
        private var found = false

        init(onSuccess: @escaping (String) -> Void) {
            self.onSuccess = onSuccess
        }

        func attach(_ webView: WKWebView) {
            self.webView = webView
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pollCookies()
            if pollTimer == nil {
                pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.pollCookies() }
                }
            }
        }

        func pollCookies() {
            guard !found, !onSuccessFired, let webView else { return }
            let store = webView.configuration.websiteDataStore.httpCookieStore
            store.getAllCookies { [weak self] cookies in
                guard let self, !self.found else { return }
                let wereadCookies = cookies.filter { $0.domain.hasSuffix("weread.qq.com") }
                // wr_skey 出现且非空 = 网页版登录态有效
                if wereadCookies.contains(where: { $0.name == "wr_skey" && !$0.value.isEmpty }) {
                    self.found = true
                    DispatchQueue.main.async {
                        self.stopPolling()
                        let header = wereadCookies
                            .map { "\($0.name)=\($0.value)" }
                            .joined(separator: "; ")
                        WeReadContentService.shared.cookie = header
                        self.fireSuccess(header)
                    }
                }
            }
        }

        private var onSuccessFired = false

        private func fireSuccess(_ header: String) {
            guard !onSuccessFired else { return }
            onSuccessFired = true
            onSuccess(header)
        }

        func stopPolling() {
            pollTimer?.invalidate()
            pollTimer = nil
            webView?.stopLoading()
        }
    }
}
