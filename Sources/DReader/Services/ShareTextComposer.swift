import Foundation

/// 划线分享为纯文本的格式模板（金句卡分享动作的下拉选项与测试共用的纯函数层）。
enum ShareTextFormat: String, CaseIterable, Identifiable {
    case quoteWithThought   // 「引文 + 我的思考 + 出处」
    case quoteOnly          // 「仅引文 + 出处」
    case thoughtFirst       // 思考主导：思考在上，引文出处垫底

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .quoteWithThought: return "引文 + 我的思考"
        case .quoteOnly: return "仅引文"
        case .thoughtFirst: return "主打思考"
        }
    }
}

/// 分享文字组装与 X（Twitter）发帖 URL 构造 —— 纯函数、零 AppKit 依赖，便于单测。
enum ShareTextComposer {
    /// 组装文字版划线分享。
    /// 作者优先取本地 EPUB 元数据，微信笔记退回同步来的原作者；微信来源追加 via 标注。
    /// 不做繁简转换：用户读到什么就分享什么。
    static func composeText(format: ShareTextFormat, highlight: Highlight, book: EPUBBook?) -> String {
        let title = highlight.bookTitle.isEmpty ? (book?.title ?? "未知书目") : highlight.bookTitle
        var author: String? = nil
        if let bookAuthor = book?.author, !bookAuthor.isEmpty {
            author = bookAuthor
        } else {
            author = highlight.wechatAuthor
        }

        var source = "《\(title)》"
        if let author, !author.isEmpty {
            source += " · \(author)"
        }
        if !highlight.chapterTitle.isEmpty {
            source += " · \(highlight.chapterTitle)"
        }
        if highlight.isFromWeChatRead {
            source += "（via 微信读书）"
        }

        let quoteLine = "“\(highlight.text)”\n—— \(source)"
        let thought = highlight.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if thought.isEmpty {
            return quoteLine
        }
        switch format {
        case .quoteOnly:
            return quoteLine
        case .quoteWithThought:
            return "“\(highlight.text)”\n\n💭 我的思考：\(thought)\n—— \(source)"
        case .thoughtFirst:
            return "💭 我的思考：\(thought)\n\n“\(highlight.text)”\n—— \(source)"
        }
    }

    /// X 发帖窗 URL：文字直接进输入框；超过 X 字数上限先按加权截断。
    static func xPostURL(text: String) -> URL? {
        var comps = URLComponents(string: "https://x.com/intent/post")
        comps?.queryItems = [URLQueryItem(name: "text", value: truncateForX(text))]
        return comps?.url
    }

    /// X 的推文按加权字符计数（CJK/emoji 记 2，其余记 1），上限 280 单位。
    /// 超限时截到 276 单位并补省略号（预留 2 单位），保证最终不越限。
    static func truncateForX(_ text: String, limit: Int = 278) -> String {
        if weightedLength(text) <= limit { return text }
        var weight = 0
        for index in text.indices {
            let width = characterWeight(text[index])
            if weight + width > limit - 2 {
                return String(text[..<index]) + "…"
            }
            weight += width
        }
        return text
    }

    static func weightedLength(_ text: String) -> Int {
        text.reduce(0) { $0 + characterWeight($1) }
    }

    private static func characterWeight(_ character: Character) -> Int {
        if character.unicodeScalars.allSatisfy({ $0.value < 0x80 }) { return 1 }
        for scalar in character.unicodeScalars {
            switch scalar.value {
            case 0x1100...0x11FF,      // 谚文字母
                 0x3000...0x303F,      // CJK 标点
                 0x2E80...0x9FFF,      // CJK 部首至统一表意文字
                 0xF900...0xFAFF,      // CJK 兼容表意
                 0xFF00...0xFF60,      // 全角符号
                 0x1F300...0x1F9FF:    // 补充符号区 emoji
                return 2
            default:
                continue
            }
        }
        return 1
    }
}
