import AppKit

/// 零凭据社交分享（X/Twitter 先行）：文字走 x.com 发帖窗、卡片图自动进剪贴板，
/// 系统分享菜单兜底其他平台。全程不落任何账号信息、不调用任何 API。
@MainActor
enum SocialShare {
    /// 一键发 X：卡片图进剪贴板，默认浏览器打开发帖窗（文字已带上，⌘V 粘贴图文）。
    /// 返回按钮反馈文案。
    static func shareToX(text: String, image: NSImage?) -> String {
        if let image {
            copyImage(image)
        }
        if let url = ShareTextComposer.xPostURL(text: text) {
            NSWorkspace.shared.open(url)
        }
        guard image != nil else { return "已打开 X 发帖窗" }
        return "卡片图已复制；已打开 X 发帖窗，⌘V 粘贴"
    }

    static func copyImage(_ image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    static func copyText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
