import SwiftUI
import AppKit

enum QuoteCardTheme: String, CaseIterable, Identifiable {
    case sepia = "典雅羊皮纸"
    case white = "纯净白昼"
    case gray = "极简亚麻灰"
    case dark = "暖夜深褐"
    case oled = "黑曜极夜"
    case classicalVertical = "古典竖排"

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
        case .classicalVertical:
            return [Color(hex: "#F6EFDF"), Color(hex: "#EFE6D0")]
        }
    }

    var textColor: Color {
        switch self {
        case .sepia: return Color(hex: "#2E241E")
        case .white: return Color(hex: "#1C1C1E")
        case .gray: return Color(hex: "#222120")
        case .dark: return Color(hex: "#E5DFD5")
        case .oled: return Color(hex: "#EAEAEB")
        case .classicalVertical: return Color(hex: "#33261C")
        }
    }

    var secondaryColor: Color {
        switch self {
        case .sepia: return Color(hex: "#7A6B5D")
        case .white: return Color(hex: "#6E6E73")
        case .gray: return Color(hex: "#68686D")
        case .dark: return Color(hex: "#998F84")
        case .oled: return Color(hex: "#8E8E93")
        case .classicalVertical: return Color(hex: "#8A7358")
        }
    }

    var accentColor: Color {
        switch self {
        case .sepia: return Color(hex: "#8E5123")
        case .white: return Color(hex: "#0066CC")
        case .gray: return Color(hex: "#2563EB")
        case .dark: return Color(hex: "#D4AF37")
        case .oled: return Color(hex: "#A78BFA")
        case .classicalVertical: return Color(hex: "#A83226")
        }
    }

    var isDark: Bool {
        self == .dark || self == .oled
    }

    var isVertical: Bool {
        self == .classicalVertical
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
    @State private var textFormat: ShareTextFormat = .quoteWithThought
    @State private var shareNote: String? = nil // 分享动作反馈（含剪贴板提示），2.5s 自动收
    @State private var showSystemShare: Bool = false

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

                    // The Renderable Quote Card Preview（阴影只属于预览层，导出走纯净卡片边界）
                    cardContent
                        .shadow(color: Color.black.opacity(0.22), radius: 18, x: 0, y: 8)
                        .padding(.vertical, 4)

                    Spacer(minLength: 12)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }

            Divider()
                .opacity(0.25)

            // Bottom Action Bar
            actionBar
        }
        .frame(minWidth: 460, idealWidth: 500, maxWidth: 540, minHeight: 460, idealHeight: 520, maxHeight: 600)
        .background(.ultraThinMaterial)
    }

    // MARK: - Header Bar
    private var headerBar: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "photo.artframe")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
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
                                .overlay(Circle().stroke(selectedTheme == theme ? Color.primary.opacity(0.7) : Color.primary.opacity(0.2), lineWidth: selectedTheme == theme ? 2 : 0.6))

                            Text(theme.rawValue)
                                .font(.system(size: 11, weight: selectedTheme == theme ? .semibold : .regular))
                                .foregroundStyle(selectedTheme == theme ? .primary : .secondary)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(selectedTheme == theme ? Color.primary.opacity(0.08) : Color.primary.opacity(0.04))
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
    @ViewBuilder
    private var cardContent: some View {
        if selectedTheme.isVertical {
            classicalVerticalCard
        } else {
            horizontalCard
        }
    }

    // MARK: 古典竖排卡（右起竖文 · 朱砂印章落款）

    private var classicalVerticalCard: some View {
        HStack(alignment: .top, spacing: 14) {
            // 最左：印章与出处（竖排卡落款在左下）
            VStack(spacing: 8) {
                Spacer()

                // 朱砂印章式 DReader 落款
                Text("读\u{3000}书")
                    .font(.system(size: 12, weight: .bold, design: .serif))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 52)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color(hex: "#A83226").opacity(0.88))
                    )
                    .shadow(color: Color(hex: "#A83226").opacity(0.3), radius: 3, x: 0, y: 1.5)

                Text("《\(highlight.bookTitle.isEmpty ? (book?.title ?? "未知书目") : highlight.bookTitle)》")
                    .font(.system(size: 10.5, weight: .semibold, design: .serif))
                    .foregroundStyle(selectedTheme.secondaryColor)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text(book?.author ?? "未知作者")
                    .font(.system(size: 9, design: .serif))
                    .foregroundStyle(selectedTheme.secondaryColor.opacity(0.75))
                    .lineLimit(1)
            }
            .frame(width: 86)

            // 正文：竖排从右向左
            VStack(spacing: 10) {
                Text(highlight.text)
                    .font(.system(size: 15.5, weight: .regular, design: .serif))
                    .foregroundStyle(selectedTheme.textColor)
                    .lineSpacing(8)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxHeight: .infinity, alignment: .top)

                if includeThought, let note = highlight.note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("💭 \(note)")
                        .font(.system(size: 11.5, design: .serif))
                        .foregroundStyle(selectedTheme.textColor.opacity(0.85))
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(highlight.chapterTitle)
                    .font(.system(size: 10, design: .serif))
                    .foregroundStyle(selectedTheme.secondaryColor.opacity(0.85))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.layoutDirection, .rightToLeft) // 视觉上从右往左排列

            // 最右：开卷语与装饰（右起首列）
            VStack(spacing: 6) {
                Text("“")
                    .font(.system(size: 30, weight: .bold, design: .serif))
                    .foregroundStyle(selectedTheme.accentColor.opacity(0.55))

                Rectangle()
                    .fill(selectedTheme.accentColor.opacity(0.35))
                    .frame(width: 1.2, height: 46)

                Text("書")
                    .font(.system(size: 13, weight: .medium, design: .serif))
                    .foregroundStyle(selectedTheme.accentColor.opacity(0.7))
            }
        }
        .padding(20)
        .frame(width: 380, height: 300)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: selectedTheme.bgColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color(hex: "#A83226").opacity(0.22), lineWidth: 0.8)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var horizontalCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Top Ornament & Chapter Header
            HStack(alignment: .top) {
                Text("“")
                    .font(.system(size: 38, weight: .bold, design: .serif))
                    .foregroundStyle(selectedTheme.accentColor.opacity(0.55))
                    .frame(height: 24)
                    .offset(y: 4)

                Spacer()

                Text(highlight.chapterTitle)
                    .font(.system(size: 10.5, weight: .medium, design: .serif))
                    .foregroundStyle(selectedTheme.secondaryColor.opacity(0.85))
                    .lineLimit(1)
            }

            // Main Quoted Text
            Text(highlight.text)
                .font(.system(size: 14.5, weight: .regular, design: .serif))
                .foregroundStyle(selectedTheme.textColor)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Attached Thought Box
            if includeThought, let note = highlight.note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text("💭 读者思考")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(selectedTheme.accentColor)

                        Spacer()

                        Text(highlight.createdAt.formatted(date: .numeric, time: .omitted))
                            .font(.system(size: 8.5))
                            .foregroundStyle(selectedTheme.secondaryColor.opacity(0.7))
                    }

                    Text(note)
                        .font(.system(size: 11.5, weight: .regular))
                        .foregroundStyle(selectedTheme.textColor.opacity(0.92))
                        .lineSpacing(2)
                }
                .padding(8)
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
        .padding(20)
        .frame(width: 360)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: selectedTheme.bgColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(selectedTheme.isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.08), lineWidth: 0.8)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Bottom Action Bar（双行：主行 X 分享 + 次行其余分发动作）
    private var actionBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Text("生成高清卡片图，一键分发到社交平台")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Spacer()

                // 分享到 X（主路径）：文字进发帖窗、卡片图自动进剪贴板
                Button {
                    shareToX()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "paperplane.fill")
                        Text(shareNote ?? "分享到 X")
                            .lineLimit(1)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(shareNote == nil ? Color(nsColor: .controlAccentColor) : Color.green.opacity(0.9))
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                }
                .help("打开 X 发帖窗；卡片图自动进剪贴板，⌘V 粘贴图文")
            }

            HStack(spacing: 12) {
                Spacer()

                // 系统分享菜单：邮件/短信/其他客户端零成本接入
                Button {
                    showSystemShare = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "square.and.arrow.up")
                        Text("系统分享")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.primary.opacity(0.06))
                    .foregroundStyle(Color.primary)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("调用 macOS 系统分享菜单（邮件、消息、其他客户端等）")

                // 复制文字版：点击即复制当前格式；侧箭头切格式
                Menu(
                    content: {
                        Picker("文字格式", selection: $textFormat) {
                            ForEach(ShareTextFormat.allCases) { format in
                                Text(format.displayName).tag(format)
                            }
                        }
                    },
                    label: {
                        HStack(spacing: 5) {
                            Image(systemName: "text.quote")
                            Text("复制文字版")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color.primary.opacity(0.06))
                        .foregroundStyle(Color.primary)
                        .clipShape(Capsule())
                    },
                    primaryAction: {
                        copyShareText()
                    }
                )
                .menuStyle(.button)
                .fixedSize()
                .help("复制文字版划线（按所选格式）")

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
                        Text(saveFeedback ? "保存成功！" : "保存高清 PNG")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.primary.opacity(0.06))
                    .foregroundStyle(Color.primary)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .overlay {
            if showSystemShare {
                SharingServicePickerLauncher(items: systemShareItems()) {
                    showSystemShare = false
                }
                .frame(width: 24, height: 12)
                .opacity(0.01)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Share Actions

    @MainActor
    private func shareToX() {
        // 「包含思考」勾选时文字版也带上思考；未勾选走纯引文
        let format: ShareTextFormat = (includeThought && hasThought) ? .quoteWithThought : .quoteOnly
        let note = SocialShare.shareToX(
            text: ShareTextComposer.composeText(format: format, highlight: highlight, book: book),
            image: generateCardNSImage()
        )
        flashShareNote(note)
    }

    @MainActor
    private func copyShareText() {
        SocialShare.copyText(
            ShareTextComposer.composeText(format: textFormat, highlight: highlight, book: book)
        )
        flashShareNote("文字版已复制")
    }

    /// 系统分享菜单投递内容：卡片图优先；生成失败退回纯文本
    @MainActor
    private func systemShareItems() -> [Any] {
        let text = ShareTextComposer.composeText(format: textFormat, highlight: highlight, book: book)
        if let image = generateCardNSImage() {
            return [image, text]
        }
        return [text]
    }

    @MainActor
    private func flashShareNote(_ note: String) {
        shareNote = note
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            shareNote = nil
        }
    }

    // MARK: - Image Rendering Actions
    @MainActor
    private func generateCardNSImage() -> NSImage? {
        // 3x 超采样导出，卡片背景已在源视图内含纯色兜底（不透明），
        // 导出内容不含投影 —— 分享到微信/微博等白底场景不会出现灰脏半透明边。
        let renderer = ImageRenderer(content: cardContent)
        renderer.scale = 3.0
        guard let cgImage = renderer.cgImage else { return renderer.nsImage }

        // 经 8-bit RGBA 位图上下文落盘，避免 TIFF 往返造成的色彩/透明度损耗
        let width = cgImage.width
        let height = cgImage.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let flattened = context.makeImage() else { return nil }
        return NSImage(cgImage: flattened, size: NSSize(width: width / 3, height: height / 3))
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

/// 系统分享菜单宿主：按钮触发时挂载一层隐形 NSView，在它锚点上原地弹 NSSharingServicePicker。
private struct SharingServicePickerLauncher: NSViewRepresentable {
    let items: [Any]
    let onPresented: () -> Void

    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        DispatchQueue.main.async {
            let picker = NSSharingServicePicker(items: items)
            picker.show(relativeTo: host.bounds, of: host, preferredEdge: .maxY)
            onPresented()
        }
        return host
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
