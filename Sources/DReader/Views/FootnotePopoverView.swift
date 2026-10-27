import SwiftUI

/// In-page footnote popover (click-to-bubble instead of jumping away).
/// Apple Books style: compact glass card anchored right above the footnote number.
struct FootnotePopoverView: View {
    let footnote: FootnoteCardInfo
    var onDismiss: () -> Void
    var onAskAI: ((String) -> Void)? = nil

    private let maxCardWidth: CGFloat = 420
    private let maxCardHeight: CGFloat = 340

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "superscript")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(Color(hex: "#8E5123"))
                    .clipShape(Circle())
                Text("脚注")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !footnote.longContent {
                    tooltipButton(icon: "sparkles", help: "让 AI 解读此脚注") {
                        onAskAI?(footnote.text)
                    }
                }
                tooltipButton(icon: "doc.on.doc", help: "复制脚注内容") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(footnote.text, forType: .string)
                }
                tooltipButton(icon: "xmark", help: "关闭") {
                    onDismiss()
                }
            }

            ScrollView {
                Text(footnote.text)
                    .font(.system(size: 12.5, design: .serif))
                    .lineSpacing(3.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: footnote.longContent ? maxCardHeight : nil)
        }
        .padding(11)
        .frame(width: maxCardWidth)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
        .onTapGesture {}
    }

    private func tooltipButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .padding(4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
