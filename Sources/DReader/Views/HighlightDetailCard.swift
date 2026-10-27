import SwiftUI
import AppKit

/// 微信读书范式：点已有划线弹出的是一条紧凑工具条（单行，~44pt），
/// 而非内容卡片。划线原文就在背后页面上抬头可见，无需重复引用；
/// 「写想法」按需临时展开一个小输入框，完事收回。
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
            // 主行：色板 + 操作按钮（单行工具条）
            HStack(spacing: 6) {
                // Color dots (tap to switch highlight color)
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

                Spacer(minLength: 4)

                // 写想法 / 编辑想法
                Button {
                    thoughtDraft = highlight.note ?? ""
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isEditingThought = true
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: hasThought ? "text.bubble" : "square.and.pencil")
                            .font(.system(size: 9.5))
                        Text(hasThought ? "想法" : "写想法")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .foregroundStyle(.purple)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3.5)
                    .background(Color.purple.opacity(0.12))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(hasThought ? "查看 / 编辑想法" : "写下此处的想法")

                // Ask AI
                Button {
                    onAskAI(highlight.text)
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 9, weight: .bold))
                        Text("问AI")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .foregroundStyle(.purple)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3.5)
                    .background(Color.purple.opacity(0.1))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("结合划线向 AI 深度请教")

                // Quote Card
                Button {
                    onMakeQuoteCard()
                } label: {
                    Image(systemName: "photo.artframe")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.indigo)
                        .frame(width: 22, height: 22)
                        .background(Color.indigo.opacity(0.08))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("制作精美金句书摘卡片")

                // Delete
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.red.opacity(0.8))
                        .frame(width: 22, height: 22)
                        .background(Color.red.opacity(0.08))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("删除划线")

                // Close
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
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
                                .stroke(Color.purple.opacity(0.4), lineWidth: 1)
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
                                .foregroundStyle(.white)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 3.5)
                                .background(Color.purple)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 300)
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

/// 弹卡毛玻璃底板与投影（拆出独立扩展，缓解主 body 类型检查压力）
private extension View {
    func cardPopoverChrome() -> some View {
        background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.22), radius: 14, x: 0, y: 6)
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(Color.white.opacity(0.28), lineWidth: 0.6)
                )
        )
    }
}
