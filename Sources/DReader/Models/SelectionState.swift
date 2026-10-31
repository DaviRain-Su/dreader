import Foundation
import CoreGraphics

/// Represents the active text selection inside the reader
struct SelectionInfo: Equatable, Sendable {
    let text: String
    let x: CGFloat
    let y: CGFloat
    let bottomY: CGFloat
    let width: CGFloat
    let height: CGFloat
    /// 选区前后各 ~24 字符(JS 端从所在文本节点截取):恢复划线时消歧同文本多处
    var prefix: String?
    var suffix: String?
}

/// Active highlight card (when clicking an existing highlight)
struct HighlightCardInfo: Equatable, Sendable {
    let highlightId: UUID
    let x: CGFloat
    let y: CGFloat
    let bottomY: CGFloat
}

/// Active footnote popover (clicking a numbered footnote reference)
struct FootnoteCardInfo: Equatable, Sendable {
    let text: String
    let x: CGFloat
    let y: CGFloat
    let bottomY: CGFloat
    var longContent: Bool { text.count > 900 }
}

@Observable
final class ReaderSelectionManager: @unchecked Sendable {
    var activeSelection: SelectionInfo?
    var activeHighlightCard: HighlightCardInfo?
    var activeFootnoteCard: FootnoteCardInfo?
    var isAIPanelVisible: Bool = true
    var quoteForAI: String?
    /// 无选区按 H/N 时的轻提示（“先选中一段文字”），2 秒后自动清空
    var selectionHint: String?

    func clear() {
        activeSelection = nil
        activeHighlightCard = nil
        activeFootnoteCard = nil
    }
}
