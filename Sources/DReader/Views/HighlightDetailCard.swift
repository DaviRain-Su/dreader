import SwiftUI
import AppKit

/// WeChat Read (微信读书) Style Highlight & Thought Popover Card
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
        VStack(alignment: .leading, spacing: 10) {
            // Header: Color Palette & Action Buttons
            HStack(spacing: 8) {
                // Color dots (tap to switch highlight color)
                HStack(spacing: 5) {
                    ForEach(colors, id: \.hex) { item in
                        Circle()
                            .fill(item.color)
                            .frame(width: 17, height: 17)
                            .overlay(
                                Circle()
                                    .stroke(Color.primary.opacity(item.hex == highlight.colorHex ? 0.8 : 0.15),
                                            lineWidth: item.hex == highlight.colorHex ? 2 : 0.5)
                            )
                            .overlay(
                                Image(systemName: "checkmark")
                                    .font(.system(size: 8, weight: .black))
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

                Spacer()

                // Ask AI Button
                Button {
                    onAskAI(highlight.text)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10, weight: .bold))
                        Text("问 AI")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.purple)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3.5)
                    .background(Color.purple.opacity(0.12))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("结合划线向 AI 深度请教")

                // Quote Card Button
                Button {
                    onMakeQuoteCard()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "photo.artframe")
                            .font(.system(size: 10, weight: .bold))
                        Text("卡片")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.indigo)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3.5)
                    .background(Color.indigo.opacity(0.12))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("制作微信读书风格精美金句卡片")

                // Copy Button
                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    var contentToCopy = "「\(highlight.text)」"
                    if let note = highlight.note, !note.isEmpty {
                        contentToCopy += "\n\n想法：\(note)"
                    }
                    contentToCopy += "\n—— 出自《\(highlight.bookTitle)》\(highlight.chapterTitle)"
                    pasteboard.setString(contentToCopy, forType: .string)
                    copyFeedback = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        copyFeedback = false
                    }
                } label: {
                    Image(systemName: copyFeedback ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(copyFeedback ? .green : .secondary)
                        .frame(width: 24, height: 24)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("复制划线及想法")

                // Delete Button
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.red.opacity(0.85))
                        .frame(width: 24, height: 24)
                        .background(Color.red.opacity(0.08))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("删除此划线及想法")

                // Close Button
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("关闭 (Esc)")
            }

            // Middle: Thoughts Section (Display / Edit)
            if isEditingThought {
                VStack(alignment: .leading, spacing: 6) {
                    TextEditor(text: $thoughtDraft)
                        .font(.system(size: 12.5))
                        .frame(height: 72)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(Color.primary.opacity(0.03))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.purple.opacity(0.4), lineWidth: 1)
                        )

                    HStack {
                        Text("按 ⌘+Enter 快速保存")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button("取消") {
                            isEditingThought = false
                        }
                        .font(.system(size: 11))
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)

                        Button {
                            onSaveThought(thoughtDraft)
                            isEditingThought = false
                        } label: {
                            Text("保存想法")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Color.purple)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.return, modifiers: .command)
                    }
                }
            } else if let note = highlight.note, !note.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        HStack(spacing: 4) {
                            Text("💭")
                                .font(.system(size: 11))
                            Text("我的想法")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.primary.opacity(0.8))
                        }

                        if let date = highlight.updatedAt ?? highlight.createdAt as Date? {
                            Text(dateFormatted(date))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button {
                            thoughtDraft = note
                            isEditingThought = true
                        } label: {
                            HStack(spacing: 2) {
                                Image(systemName: "pencil")
                                    .font(.system(size: 9))
                                Text("编辑")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .foregroundStyle(Color.purple)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.purple.opacity(0.08))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }

                    Text(note)
                        .font(.system(size: 12.5, weight: .regular))
                        .foregroundStyle(Color.primary.opacity(0.92))
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color.primary.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            } else {
                Button {
                    thoughtDraft = ""
                    isEditingThought = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 11))
                        Text("写想法 (写下此刻的思索与感悟)")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundStyle(Color.purple)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)
                    .background(Color.purple.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.purple.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    )
                }
                .buttonStyle(.plain)
            }

            // Bottom: Quoted Text with color indicator
            HStack(alignment: .top, spacing: 6) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color(hex: highlight.colorHex))
                    .frame(width: 3)

                Text(highlight.text)
                    .font(.system(size: 11.5, design: .serif))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 2)
        }
        .padding(14)
        .frame(width: 324)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.24), radius: 16, x: 0, y: 8)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.28), lineWidth: 0.6)
                )
        )
        .onAppear {
            if let note = highlight.note, !note.isEmpty {
                thoughtDraft = note
            }
        }
    }

    private func dateFormatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
