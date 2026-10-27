import SwiftUI
import AppKit

/// 微信读书范式：点已有划线弹出的是一条紧凑工具条（单行，~44pt），
/// 而非内容卡片。划线原文就在背后页面上抬头可见，无需重复引用；
/// 「写想法」按需临时展开一个小输入框，完事收回。
/// 色彩纪律：全条无彩单色，唯一的彩色是五个划线色点本身。
struct HighlightDetailCard: View {
    let highlight: Highlight
    let onUpdateColor: (String) -> Void
    let onSaveThought: (String) -> Void
    let onDelete: () -> Void
    let onAskAI: (String) -> Void
    let onMakeQuoteCard: () -> Void
    let onDismiss: () -> Void

    @State private var isEditingThought: Bool = false
    @State private var thoughtDraft: String = ""
    @State private var dragOffset: CGSize = .zero

    private let colors: [(name: String, hex: String, color: Color)] = [
        ("黄色", "#FFE066", Color(hex: "#FFE066")),
        ("绿色", "#99E9F2", Color(hex: "#99E9F2")),
        ("青蓝", "#A5D8FF", Color(hex: "#A5D8FF")),
        ("粉紫", "#E599F7", Color(hex: "#E599F7")),
        ("橙色", "#FFC078", Color(hex: "#FFC078"))
    ]

    private var hasThought: Bool {
        !(highlight.note?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 主行：色板 + 操作按钮（单行工具条，无彩单色）
            HStack(spacing: 2) {
                // Color dots (tap to switch highlight color) —— 全条唯一的彩色
                HStack(spacing: 4) {
                    ForEach(colors, id: \.hex) { item in
                        Circle()
                            .fill(item.color)
                            .frame(width: 14, height: 14)
                            .overlay(
                                Circle()
                                    .stroke(Color.primary.opacity(item.hex == highlight.colorHex ? 0.8 : 0.15),
                                            lineWidth: item.hex == highlight.colorHex ? 1.8 : 0.5)
                            )
                            .overlay(
                                Image(systemName: "checkmark")
                                    .font(.system(size: 7, weight: .black))
                                    .foregroundStyle(Color.black.opacity(0.8))
                                    .opacity(item.hex == highlight.colorHex ? 1 : 0)
                            )
                            .contentShape(Circle())
                            .onTapGesture {
                                onUpdateColor(item.hex)
                            }
                            .help("更换为\(item.name)划线")
                    }
                }
                .padding(.horizontal, 2)

                Divider()
                    .frame(height: 12)
                    .opacity(0.25)

                // 写想法 / 编辑想法
                Button {
                    thoughtDraft = highlight.note ?? ""
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isEditingThought = true
                    }
                } label: {
                    Image(systemName: hasThought ? "text.bubble" : "square.and.pencil")
                        .font(.system(size: 11))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(ChromeToolButtonStyle())
                .help(hasThought ? "查看 / 编辑想法" : "写下此处的想法")

                // Ask AI
                Button {
                    onAskAI(highlight.text)
                } label: {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(ChromeToolButtonStyle())
                .help("结合划线向 AI 深度请教")

                // Quote Card
                Button {
                    onMakeQuoteCard()
                } label: {
                    Image(systemName: "photo.artframe")
                        .font(.system(size: 11))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(ChromeToolButtonStyle())
                .help("制作精美金句书摘卡片")

                // Delete
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10.5))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(ChromeToolButtonStyle(destructive: true))
                .help("删除划线")

                Divider()
                    .frame(height: 12)
                    .opacity(0.25)

                // Close
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(ChromeToolButtonStyle())
                .help("关闭 (Esc)")
            }

            // 想法编辑态：临时展开的小输入框（仅此时卡变高，保存/取消即收回）
            if isEditingThought {
                VStack(alignment: .leading, spacing: 5) {
                    TextEditor(text: $thoughtDraft)
                        .font(.system(size: 12))
                        .frame(height: 56)
                        .scrollContentBackground(.hidden)
                        .padding(5)
                        .background(Color.primary.opacity(0.03))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                        )

                    HStack {
                        Spacer()

                        Button("取消") {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                isEditingThought = false
                            }
                        }
                        .font(.system(size: 10.5))
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)

                        Button {
                            onSaveThought(thoughtDraft)
                            withAnimation(.easeInOut(duration: 0.15)) {
                                isEditingThought = false
                            }
                        } label: {
                            Text("保存想法")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(Color(nsColor: .controlAccentColor))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 3.5)
                                .background(Color.primary.opacity(0.07))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(8)
        .frame(width: 268)
        .fixedSize(horizontal: true, vertical: false)
        .cardPopoverChrome()
        .onAppear {
            if let note = highlight.note, !note.isEmpty {
                thoughtDraft = note
            }
        }
        // 整卡可拖动（编辑态禁用，避免与 TextEditor 手势冲突）
        .offset(dragOffset)
        .simultaneousGesture(dragGesture)
    }

    /// 整卡拖动手势；编辑想法时禁用，避免与 TextEditor 手势冲突
    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard !isEditingThought else { return }
                dragOffset = value.translation
            }
    }
}

/// 弹窗工具条统一按键风格：无彩单色，悬停淡灰底，破坏性操作悬停转红
struct ChromeToolButtonStyle: ButtonStyle {
    var destructive: Bool = false

    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(
                configuration.isPressed
                    ? Color.primary.opacity(0.55)
                    : (isHovering && destructive ? Color.red.opacity(0.9) : Color.primary.opacity(0.62))
            )
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHovering ? Color.primary.opacity(0.08) : Color.clear)
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .onHover { isHovering = $0 }
    }
}

/// 弹卡毛玻璃底板与投影（拆出独立扩展，缓解主 body 类型检查压力）
private extension View {
    func cardPopoverChrome() -> some View {
        background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 5)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.22), lineWidth: 0.5)
                )
        )
    }
}
