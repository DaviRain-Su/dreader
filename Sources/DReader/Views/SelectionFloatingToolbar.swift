import SwiftUI
import AppKit

/// Apple Books & 微信读书范式：选区悬浮工具条是一条无彩玻璃胶囊，
/// 唯一的彩色是五个划线色点本身——工具不与内容争色。
struct SelectionFloatingToolbar: View {
    let selection: SelectionInfo
    let onAskAI: (String) -> Void
    let onQuickPrompt: (String, String) -> Void // (promptType, selectedText)
    let onHighlight: (String) -> Void // colorHex
    let onWriteThought: () -> Void
    let onMakeQuoteCard: () -> Void
    var onLookUp: ((String) -> Void)? = nil
    let onDismiss: () -> Void

    @State private var copyFeedback = false

    /// 键位键帽（H/N 快捷标注的可发现性）：细边框小方块，不与色点争色
    private func keyCap(_ key: String) -> some View {
        Text(key)
            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
            .foregroundStyle(Color.primary.opacity(0.45))
            .frame(width: 13, height: 13)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.primary.opacity(0.22), lineWidth: 0.6)
            )
    }

    private let highlightColors: [(name: String, hex: String, color: Color)] = [
        ("黄色", "#FFE066", Color(hex: "#FFE066")),
        ("绿色", "#99E9F2", Color(hex: "#99E9F2")),
        ("青蓝", "#A5D8FF", Color(hex: "#A5D8FF")),
        ("粉紫", "#E599F7", Color(hex: "#E599F7")),
        ("橙色", "#FFC078", Color(hex: "#FFC078"))
    ]

    var body: some View {
        HStack(spacing: 2) {
            // 1. Color Palette Dots (Click to instant highlight) —— 全条唯一的彩色
            // 色点行加 H 键帽：选中文字后直接按 H 就是划线（默认色），无需点色点
            HStack(spacing: 4) {
                ForEach(highlightColors, id: \.hex) { item in
                    Circle()
                        .fill(item.color)
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(Color.primary.opacity(0.2), lineWidth: 0.6))
                        .shadow(color: item.color.opacity(0.3), radius: 1.5, y: 0.5)
                        .contentShape(Circle())
                        .onTapGesture {
                            onHighlight(item.hex)
                        }
                        .help("划线 (\(item.name))")
                }
                keyCap("H")
                    .padding(.leading, 2)
            }
            .padding(.horizontal, 4)

            Divider()
                .frame(height: 14)
                .opacity(0.25)

            // 2. Write Thought
            Button {
                onWriteThought()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 11.5))
                    keyCap("N")
                }
                .frame(width: 40, height: 26)
            }
            .buttonStyle(ChromeToolButtonStyle())
            .help("划线并记录读书思考与笔记（快捷键 N）")

            // 3. Quote Card
            Button {
                onMakeQuoteCard()
            } label: {
                Image(systemName: "photo.artframe")
                    .font(.system(size: 11.5))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(ChromeToolButtonStyle())
            .help("制作精美金句书摘卡片")

            // 4. Dictionary Look Up
            Button {
                onLookUp?(selection.text)
            } label: {
                Image(systemName: "character.book.closed")
                    .font(.system(size: 11.5))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(ChromeToolButtonStyle())
            .help("发音朗读并调用 AI 展开权威词典深度释义")

            // 5. Ask AI
            Button {
                onAskAI(selection.text)
            } label: {
                Image(systemName: "sparkles")
                    .font(.system(size: 11.5, weight: .semibold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(ChromeToolButtonStyle())
            .help("将选中文本发送给伴读 Agent 深度讨论")

            Divider()
                .frame(height: 14)
                .opacity(0.25)

            // 6. More Actions Menu (Copy, Explain, Summarize, Translate)
            Menu {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(selection.text, forType: .string)
                    copyFeedback = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        copyFeedback = false
                    }
                } label: {
                    Label("复制文本", systemImage: "doc.on.doc")
                }

                Divider()

                Button {
                    onQuickPrompt("explain", selection.text)
                } label: {
                    Label("AI 深度解释", systemImage: "lightbulb")
                }

                Button {
                    onQuickPrompt("summarize", selection.text)
                } label: {
                    Label("AI 提炼观点", systemImage: "text.quote")
                }

                Button {
                    onQuickPrompt("translate", selection.text)
                } label: {
                    Label("AI 上下文精译", systemImage: "character.book.closed.fill")
                }
            } label: {
                Image(systemName: copyFeedback ? "checkmark" : "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(copyFeedback ? .green : Color.primary.opacity(0.62))
                    .frame(width: 24, height: 26)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .help("更多操作 (复制 / AI解释 / 总结 / 翻译)")
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.16), radius: 10, x: 0, y: 4)
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.22), lineWidth: 0.5)
                )
        )
    }
}
