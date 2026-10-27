import SwiftUI
import AppKit

enum QuoteCardTheme: String, CaseIterable, Identifiable {
    case sepia = "典雅羊皮纸"
    case white = "纯净白昼"
    case gray = "极简亚麻灰"
    case dark = "暖夜深褐"
    case oled = "黑曜极夜"

    var id: String { rawValue }

    var bgColors: [Color] {
        switch self {
        case .sepia:
            return [Color(hex: "#F9F4EB"), Color(hex: "#F4EDE0")]
        case .white:
            return [Color(hex: "#FFFFFF"), Color(hex: "#F7F7F8")]
        case .gray:
            return [Color(hex: "#ECE9E4"), Color(hex: "#E4E0D9")]
        case .dark:
            return [Color(hex: "#23211F"), Color(hex: "#1A1918")]
        case .oled:
            return [Color(hex: "#161617"), Color(hex: "#0E0E0F")]
        }
    }

    var textColor: Color {
        switch self {
        case .sepia: return Color(hex: "#2E241E")
        case .white: return Color(hex: "#1C1C1E")
        case .gray: return Color(hex: "#222120")
        case .dark: return Color(hex: "#E5DFD5")
        case .oled: return Color(hex: "#EAEAEB")
        }
    }

    var secondaryColor: Color {
        switch self {
        case .sepia: return Color(hex: "#7A6B5D")
        case .white: return Color(hex: "#6E6E73")
        case .gray: return Color(hex: "#68686D")
        case .dark: return Color(hex: "#998F84")
        case .oled: return Color(hex: "#8E8E93")
        }
    }

    var accentColor: Color {
        switch self {
        case .sepia: return Color(hex: "#8E5123")
        case .white: return Color(hex: "#0066CC")
        case .gray: return Color(hex: "#2563EB")
        case .dark: return Color(hex: "#D4AF37")
        case .oled: return Color(hex: "#A78BFA")
        }
    }

    var isDark: Bool {
        self == .dark || self == .oled
    }
}

/// Aesthetic Quote Card Generator Modal View (WeChat Read & Apple Books style)
struct QuoteCardView: View {
    let highlight: Highlight
    let book: EPUBBook?
    let onClose: () -> Void

    @State private var selectedTheme: QuoteCardTheme = .sepia
    @State private var includeThought: Bool = true
    @State private var copyFeedback: Bool = false
    @State private var saveFeedback: Bool = false

    private var hasThought: Bool {
        !(highlight.note?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Modal Navigation Header
            headerBar

            Divider()
                .opacity(0.25)

            // Scrollable Content
            ScrollView {
                VStack(spacing: 24) {
                    // Theme Switcher & Options Bar
                    controlPanel

                    // The Renderable Quote Card Preview
                    cardContent
                        .padding(.vertical, 8)

                    Spacer(minLength: 16)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
            }

            Divider()
                .opacity(0.25)

            // Bottom Action Bar
            actionBar
        }
        .frame(minWidth: 540, idealWidth: 580, maxWidth: 640, minHeight: 620, idealHeight: 700)
        .background(.ultraThinMaterial)
    }

    // MARK: - Header Bar
    private var headerBar: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "photo.artframe")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.purple)
                Text("制作读书金句卡片")
                    .font(.system(size: 14, weight: .semibold))
            }

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("关闭 (Esc)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Controls Panel
    private var controlPanel: some View {
        HStack(spacing: 16) {
            // Theme Selector Chips
            HStack(spacing: 8) {
                ForEach(QuoteCardTheme.allCases) { theme in
                    Button {
                        selectedTheme = theme
                    } label: {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(theme.bgColors.first!)
                                .frame(width: 14, height: 14)
                                .overlay(Circle().stroke(selectedTheme == theme ? Color.purple : Color.primary.opacity(0.2), lineWidth: selectedTheme == theme ? 2 : 0.6))

                            Text(theme.rawValue)
                                .font(.system(size: 11, weight: selectedTheme == theme ? .semibold : .regular))
                                .foregroundStyle(selectedTheme == theme ? .primary : .secondary)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(selectedTheme == theme ? Color.purple.opacity(0.12) : Color.primary.opacity(0.04))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()

            // Include Thought Toggle (if available)
            if hasThought {
                Toggle(isOn: $includeThought) {
                    Text("包含思考")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    // MARK: - Core Aesthetic Quote Card Content
    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Top Ornament & Chapter Header
            HStack(alignment: .top) {
                Text("“")
                    .font(.system(size: 54, weight: .bold, design: .serif))
                    .foregroundStyle(selectedTheme.accentColor.opacity(0.55))
                    .frame(height: 32)
                    .offset(y: 8)

                Spacer()

                Text(highlight.chapterTitle)
                    .font(.system(size: 11, weight: .medium, design: .serif))
                    .foregroundStyle(selectedTheme.secondaryColor.opacity(0.85))
                    .lineLimit(1)
            }

            // Main Quoted Text
            Text(highlight.text)
                .font(.system(size: 16, weight: .regular, design: .serif))
                .foregroundStyle(selectedTheme.textColor)
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Attached Thought Box
            if includeThought, let note = highlight.note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text("💭 读者思考")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(selectedTheme.accentColor)

                        Spacer()

                        Text(highlight.createdAt.formatted(date: .numeric, time: .omitted))
                            .font(.system(size: 9))
                            .foregroundStyle(selectedTheme.secondaryColor.opacity(0.7))
                    }

                    Text(note)
                        .font(.system(size: 12.5, weight: .regular))
                        .foregroundStyle(selectedTheme.textColor.opacity(0.92))
                        .lineSpacing(2)
                }
                .padding(10)
                .background(selectedTheme.accentColor.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(selectedTheme.accentColor.opacity(0.22), lineWidth: 0.6)
                )
            }

            // Elegant Divider
            HStack {
                Rectangle()
                    .fill(selectedTheme.secondaryColor.opacity(0.2))
                    .frame(height: 0.8)
                Text("❦")
                    .font(.system(size: 12))
                    .foregroundStyle(selectedTheme.secondaryColor.opacity(0.5))
                    .padding(.horizontal, 6)
                Rectangle()
                    .fill(selectedTheme.secondaryColor.opacity(0.2))
                    .frame(height: 0.8)
            }
            .padding(.vertical, 4)

            // Footer: Book Cover & Metadata & Hallmark
            HStack(spacing: 12) {
                // Mini Cover Thumbnail
                if let coverURL = book?.coverImageURL, let nsImg = NSImage(contentsOf: coverURL) {
                    Image(nsImage: nsImg)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 32, height: 44)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .shadow(color: .black.opacity(0.2), radius: 3, x: 0, y: 1.5)
                } else {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(selectedTheme.accentColor.opacity(0.2))
                        .frame(width: 32, height: 44)
                        .overlay(
                            Image(systemName: "book.closed.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(selectedTheme.accentColor)
                        )
                }

                // Book Title & Author
                VStack(alignment: .leading, spacing: 3) {
                    Text("《\(highlight.bookTitle.isEmpty ? (book?.title ?? "未知书目") : highlight.bookTitle)》")
                        .font(.system(size: 13, weight: .bold, design: .serif))
                        .foregroundStyle(selectedTheme.textColor)
                        .lineLimit(1)

                    Text(book?.author ?? "未知作者")
                        .font(.system(size: 11, design: .serif))
                        .foregroundStyle(selectedTheme.secondaryColor)
                        .lineLimit(1)
                }

                Spacer()

                // DReader Brand Hallmark Badge
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: "books.vertical.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(selectedTheme.accentColor)
                        Text("DReader")
                            .font(.system(size: 11, weight: .bold, design: .serif))
                            .foregroundStyle(selectedTheme.textColor)
                    }
                    Text("沉浸式原生 AI 阅读器")
                        .font(.system(size: 8.5))
                        .foregroundStyle(selectedTheme.secondaryColor.opacity(0.7))
                }
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: selectedTheme.bgColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: Color.black.opacity(0.22), radius: 18, x: 0, y: 8)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(selectedTheme.isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.08), lineWidth: 0.8)
                )
        )
    }

    // MARK: - Bottom Action Bar
    private var actionBar: some View {
        HStack(spacing: 12) {
            Text("支持一键复制到剪贴板或保存为高清图片分享")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Spacer()

            // Copy Image Button
            Button {
                copyCardImage()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: copyFeedback ? "checkmark" : "doc.on.doc")
                    Text(copyFeedback ? "已复制图片！" : "复制图片")
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(copyFeedback ? Color.green.opacity(0.15) : Color.primary.opacity(0.06))
                .foregroundStyle(copyFeedback ? Color.green : Color.primary)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            // Save PNG Button
            Button {
                saveCardPNG()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: saveFeedback ? "checkmark" : "arrow.down.circle.fill")
                    Text(saveFeedback ? "保存成功！" : "保存高清 PNG...")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(Color.purple)
                .clipShape(Capsule())
                .shadow(color: Color.purple.opacity(0.3), radius: 4, y: 1.5)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Image Rendering Actions
    @MainActor
    private func generateCardNSImage() -> NSImage? {
        let renderer = ImageRenderer(content: cardContent)
        renderer.scale = 2.0 // Retina 2x high-DPI crisp export
        return renderer.nsImage
    }

    @MainActor
    private func copyCardImage() {
        guard let image = generateCardNSImage() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        copyFeedback = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copyFeedback = false
        }
    }

    @MainActor
    private func saveCardPNG() {
        guard let image = generateCardNSImage(),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let pngData = bitmap.representation(using: .png, properties: [:]) else { return }

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.png]
        savePanel.nameFieldStringValue = "《\(highlight.bookTitle.isEmpty ? (book?.title ?? "金句") : highlight.bookTitle)》金句卡片.png"
        savePanel.title = "保存金句卡片图片"

        if savePanel.runModal() == .OK, let targetURL = savePanel.url {
            try? pngData.write(to: targetURL)
            saveFeedback = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                saveFeedback = false
            }
        }
    }
}
