import SwiftUI
import AppKit

/// WeChat Read & Apple Books Style Ultra-Compact Floating Selection Toolbar
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

    private let highlightColors: [(name: String, hex: String, color: Color)] = [
        ("黄色", "#FFE066", Color(hex: "#FFE066")),
        ("绿色", "#99E9F2", Color(hex: "#99E9F2")),
        ("青蓝", "#A5D8FF", Color(hex: "#A5D8FF")),
        ("粉紫", "#E599F7", Color(hex: "#E599F7")),
        ("橙色", "#FFC078", Color(hex: "#FFC078"))
    ]

    var body: some View {
        HStack(spacing: 5) {
            // 1. Color Palette Dots (Click to instant highlight)
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
            }
            .padding(.horizontal, 2)

            Divider()
                .frame(height: 12)
                .opacity(0.3)

            // 2. Write Thought Button
            Button {
                onWriteThought()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 11))
                    Text("想法")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(.indigo)
            }
            .buttonStyle(ToolbarCompactButtonStyle())
            .help("划线并记录读书思考与笔记")

            // 3. Quote Card Button
            Button {
                onMakeQuoteCard()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "photo.artframe")
                        .font(.system(size: 11))
                    Text("卡片")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(.purple)
            }
            .buttonStyle(ToolbarCompactButtonStyle())
            .help("制作精美金句书摘卡片")

            // 4. Dictionary Look Up Button
            Button {
                onLookUp?(selection.text)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "character.book.closed")
                        .font(.system(size: 11))
                    Text("查词")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(.teal)
            }
            .buttonStyle(ToolbarCompactButtonStyle())
            .help("发音朗读并调用 AI 展开权威词典深度释义")

            // 5. Ask AI Button
            Button {
                onAskAI(selection.text)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .bold))
                    Text("问AI")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .foregroundStyle(.purple)
            }
            .buttonStyle(ToolbarCompactButtonStyle())
            .help("将选中文本发送给伴读 Agent 深度讨论")

            Divider()
                .frame(height: 12)
                .opacity(0.3)

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
                    Label("AI 深度解释", systemImage: "lightbulb.fill")
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
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(copyFeedback ? .green : .secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .help("更多操作 (复制 / AI解释 / 总结 / 翻译)")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.2), radius: 12, x: 0, y: 4)
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.28), lineWidth: 0.6)
                )
        )
    }
}

private struct ToolbarCompactButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 5)
            .padding(.vertical, 3.5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHovering ? Color.primary.opacity(0.08) : Color.clear)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .onHover { isHovering = $0 }
    }
}
