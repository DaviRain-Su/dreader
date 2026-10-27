import SwiftUI
import AppKit

/// WeChat Read (微信读书) Style Compact Highlight & Thought Popover Card
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
    @State private var copyFeedback: Bool = false

    private let colors: [(name: String, hex: String, color: Color)] = [
        ("黄色", "#FFE066", Color(hex: "#FFE066")),
        ("绿色", "#99E9F2", Color(hex: "#99E9F2")),
        ("青蓝", "#A5D8FF", Color(hex: "#A5D8FF")),
        ("粉紫", "#E599F7", Color(hex: "#E599F7")),
        ("橙色", "#FFC078", Color(hex: "#FFC078"))
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            // Header: Color Palette & Compact Action Icons
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

                // Ask AI Button
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
                    .padding(.vertical, 3)
                    .background(Color.purple.opacity(0.12))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("结合划线向 AI 深度请教")

                // Quote Card Button
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

                // Delete Button
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

                // Close Button
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

            // Middle: Thoughts Section (Display / Edit)
            if isEditingThought {
                VStack(alignment: .leading, spacing: 5) {
                    TextEditor(text: $thoughtDraft)
                        .font(.system(size: 12))
                        .frame(height: 60)
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
                            isEditingThought = false
                        }
                        .font(.system(size: 10.5))
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)

                        Button {
                            onSaveThought(thoughtDraft)
                            isEditingThought = false
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
            } else if let note = highlight.note, !note.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        HStack(spacing: 3) {
                            Text("💭")
                                .font(.system(size: 10))
                            Text("我的想法")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(Color.primary.opacity(0.8))
                        }

                        Spacer()

                        Button {
                            thoughtDraft = note
                            isEditingThought = true
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.purple)
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.plain)
                        .help("编辑想法")
                    }

                    Text(note)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.primary.opacity(0.9))
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .background(Color.primary.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            } else {
                Button {
                    thoughtDraft = ""
                    isEditingThought = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 10))
                        Text("写下此处的想法与感悟...")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(Color.purple)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 5)
                    .background(Color.purple.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.purple.opacity(0.2), style: StrokeStyle(lineWidth: 0.8, dash: [4, 3]))
                    )
                }
                .buttonStyle(.plain)
            }

            // Bottom: Quoted Text with color indicator
            HStack(alignment: .top, spacing: 6) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color(hex: highlight.colorHex))
                    .frame(width: 2.5)

                Text(highlight.text)
                    .font(.system(size: 11, design: .serif))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(11)
        .frame(width: 280)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.22), radius: 14, x: 0, y: 6)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.28), lineWidth: 0.6)
                )
        )
        .onAppear {
            if let note = highlight.note, !note.isEmpty {
                thoughtDraft = note
            }
        }
    }
}
