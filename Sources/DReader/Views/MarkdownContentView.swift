import SwiftUI
import AppKit

/// High-grade native Markdown renderer for AI reading notes & companion dialogues
struct MarkdownContentView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(parseBlocks(markdown).enumerated()), id: \.offset) { _, block in
                renderBlock(block)
            }
        }
        .textSelection(.enabled)
    }

    // MARK: - Block Definition
    enum Block {
        case h1(String)
        case h2(String)
        case h3(String)
        case blockquote(String)
        case codeBlock(code: String, language: String)
        case listItem(number: Int?, text: String)
        case divider
        case paragraph(String)
    }

    // MARK: - Parser
    private func parseBlocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 1. Code Block (```)
            if trimmed.hasPrefix("```") {
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                blocks.append(.codeBlock(code: codeLines.joined(separator: "\n"), language: lang))
                i += 1
                continue
            }

            // 2. Headings
            if trimmed.hasPrefix("### ") {
                blocks.append(.h3(String(trimmed.dropFirst(4))))
                i += 1
                continue
            } else if trimmed.hasPrefix("## ") {
                blocks.append(.h2(String(trimmed.dropFirst(3))))
                i += 1
                continue
            } else if trimmed.hasPrefix("# ") {
                blocks.append(.h1(String(trimmed.dropFirst(2))))
                i += 1
                continue
            }

            // 3. Horizontal Rule
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                blocks.append(.divider)
                i += 1
                continue
            }

            // 4. Blockquote (> ...)
            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while i < lines.count {
                    let curTrim = lines[i].trimmingCharacters(in: .whitespaces)
                    if curTrim.hasPrefix(">") {
                        let content = curTrim.dropFirst().trimmingCharacters(in: .whitespaces)
                        quoteLines.append(content)
                        i += 1
                    } else if !curTrim.isEmpty && !quoteLines.isEmpty {
                        // Multi-line continuation
                        quoteLines.append(curTrim)
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(.blockquote(quoteLines.joined(separator: "\n")))
                continue
            }

            // 5. Bullet List (- , * , • )
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
                let content = String(trimmed.dropFirst(2))
                blocks.append(.listItem(number: nil, text: content))
                i += 1
                continue
            }

            // 6. Numbered List (1. , 2. )
            if let match = matchNumberedList(trimmed) {
                blocks.append(.listItem(number: match.number, text: match.text))
                i += 1
                continue
            }

            // 7. Empty line
            if trimmed.isEmpty {
                i += 1
                continue
            }

            // 8. Normal Paragraph (gather lines until blank)
            var pLines: [String] = [line]
            i += 1
            while i < lines.count {
                let nextTrim = lines[i].trimmingCharacters(in: .whitespaces)
                if nextTrim.isEmpty || nextTrim.hasPrefix("#") || nextTrim.hasPrefix(">") ||
                    nextTrim.hasPrefix("- ") || nextTrim.hasPrefix("* ") || nextTrim.hasPrefix("```") {
                    break
                }
                pLines.append(lines[i])
                i += 1
            }
            blocks.append(.paragraph(pLines.joined(separator: "\n")))
        }

        return blocks
    }

    private func matchNumberedList(_ line: String) -> (number: Int, text: String)? {
        let parts = line.split(separator: ".", maxSplits: 1)
        if parts.count == 2, let num = Int(parts[0].trimmingCharacters(in: .whitespaces)) {
            let text = parts[1].trimmingCharacters(in: .whitespaces)
            return (num, text)
        }
        return nil
    }

    // MARK: - Block Renderers
    @ViewBuilder
    private func renderBlock(_ block: Block) -> some View {
        switch block {
        case .h1(let text):
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(text))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.primary)
                Divider()
            }
            .padding(.top, 6)

        case .h2(let text):
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.purple)
                    .frame(width: 3, height: 15)
                Text(LocalizedStringKey(text))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.primary)
            }
            .padding(.top, 4)

        case .h3(let text):
            Text(LocalizedStringKey(text))
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.purple)
                .padding(.top, 2)

        case .blockquote(let text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.purple.opacity(0.8))
                    .frame(width: 3)

                Text(LocalizedStringKey(text))
                    .font(.system(size: 12.5))
                    .italic()
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineSpacing(3)
                    .padding(.vertical, 2)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.purple.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 6))

        case .codeBlock(let code, let lang):
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(lang.isEmpty ? "文本 / 代码" : lang)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "doc.on.doc")
                            Text("复制")
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.06))

                Divider()

                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code)
                        .font(.system(size: 12, design: .monospaced))
                        .lineSpacing(3)
                        .padding(10)
                }
            }
            .background(Color.primary.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
            )

        case .listItem(let number, let text):
            HStack(alignment: .top, spacing: 6) {
                if let num = number {
                    Text("\(num).")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.purple)
                        .frame(minWidth: 16, alignment: .trailing)
                } else {
                    Circle()
                        .fill(Color.purple)
                        .frame(width: 5, height: 5)
                        .padding(.top, 6)
                }

                Text(LocalizedStringKey(text))
                    .font(.system(size: 13))
                    .lineSpacing(3)
            }
            .padding(.leading, 2)

        case .divider:
            Divider()
                .padding(.vertical, 4)

        case .paragraph(let text):
            Text(LocalizedStringKey(text))
                .font(.system(size: 13))
                .lineSpacing(3.5)
                .foregroundStyle(.primary)
        }
    }
}
