import SwiftUI
import AppKit

struct SelectionFloatingToolbar: View {
    let selection: SelectionInfo
    let onAskAI: (String) -> Void
    let onQuickPrompt: (String, String) -> Void // (promptType, selectedText)
    let onHighlight: (String) -> Void // colorHex
    let onWriteThought: () -> Void
    let onDismiss: () -> Void

    @State private var showColorPicker = false
    @State private var copyFeedback = false

    private let highlightColors: [(name: String, hex: String, color: Color)] = [
        ("黄色", "#FFE066", Color(hex: "#FFE066")),
        ("绿色", "#99E9F2", Color(hex: "#99E9F2")),
        ("青蓝", "#A5D8FF", Color(hex: "#A5D8FF")),
        ("粉紫", "#E599F7", Color(hex: "#E599F7")),
        ("橙色", "#FFC078", Color(hex: "#FFC078"))
    ]

    var body: some View {
        HStack(spacing: 4) {
            // Write Thought button (WeChat Read style)
            Button {
                onWriteThought()
            } label: {
                Label("写想法", systemImage: "square.and.pencil")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.indigo)
            }
            .buttonStyle(ToolbarButtonStyle())
            .help("划线并记录读书思考与笔记")

            // Ask AI button
            Button {
                onAskAI(selection.text)
            } label: {
                Label("问 AI", systemImage: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.purple)
            }
            .buttonStyle(ToolbarButtonStyle())
            .help("将选中文本发送给 AI 深度讨论")

            Divider()
                .frame(height: 14)
                .opacity(0.3)

            // AI Explain
            Button {
                onQuickPrompt("explain", selection.text)
            } label: {
                Label("解释", systemImage: "lightbulb.fill")
                    .font(.system(size: 12))
            }
            .buttonStyle(ToolbarButtonStyle())
            .help("让 AI 深入解释选中文本与背景")

            // AI Summarize
            Button {
                onQuickPrompt("summarize", selection.text)
            } label: {
                Label("总结", systemImage: "text.quote")
                    .font(.system(size: 12))
            }
            .buttonStyle(ToolbarButtonStyle())
            .help("提炼核心观点与关键信息")

            // AI Translate
            Button {
                onQuickPrompt("translate", selection.text)
            } label: {
                Label("翻译", systemImage: "character.book.closed.fill")
                    .font(.system(size: 12))
            }
            .buttonStyle(ToolbarButtonStyle())
            .help("精准优雅的上下文对照翻译")

            Divider()
                .frame(height: 14)
                .opacity(0.3)

            // Highlighting Color Palette
            HStack(spacing: 5) {
                ForEach(highlightColors, id: \.hex) { item in
                    Circle()
                        .fill(item.color)
                        .frame(width: 16, height: 16)
                        .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 0.8))
                        .shadow(color: item.color.opacity(0.35), radius: 2, x: 0, y: 1)
                        .contentShape(Circle())
                        .onTapGesture {
                            onHighlight(item.hex)
                        }
                        .help("使用\(item.name)划线高亮")
                }
            }
            .padding(.horizontal, 4)

            Divider()
                .frame(height: 14)
                .opacity(0.3)

            // Copy button
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(selection.text, forType: .string)
                copyFeedback = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    copyFeedback = false
                }
            } label: {
                Image(systemName: copyFeedback ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11.5))
                    .foregroundStyle(copyFeedback ? .green : .secondary)
            }
            .buttonStyle(ToolbarButtonStyle())
            .help("复制文本")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.22), radius: 14, x: 0, y: 5)
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.28), lineWidth: 0.6)
                )
        )
    }
}

private struct ToolbarButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovering ? Color.primary.opacity(0.08) : Color.clear)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .onHover { isHovering = $0 }
    }
}
