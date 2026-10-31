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

/// 高保真渲染导出：SwiftUI 视图 → sRGB 8-bit RGBA 位图 NSImage。
/// @MainActor 因 ImageRenderer/CGContext 主线程约束；渲染失败返回 nil（不降级模糊回退）。
@MainActor
enum QuoteCardImageRenderer {
    static func render(_ content: some View, scale: CGFloat = 3.0) -> NSImage? {
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        guard let cgImage = renderer.cgImage else { return nil }

        // 经 8-bit RGBA 位图上下文压平，避免 TIFF 往返造成的色彩/透明度损耗——分享到微信/微博等白底场景不会出现灰脏半透明边
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
        return NSImage(cgImage: flattened, size: NSSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale))
    }
}

/// 竖排版式工具：逐字成列（真竖排）与列内容截断。
/// Swift 的 layoutDirection 只反转堆叠方向、不旋转 Text 内字符，竖排文本必须逐字拆列。
enum QuoteCardLayout {
    /// 竖排断列：把字符串按每列 capacity 字切成多列（配合 layoutDirection .rightToLeft 即右起竖读）。
    static func verticalColumns(_ text: String, capacity: Int) -> [String] {
        let characters = Array(text)
        guard capacity > 0, !characters.isEmpty else { return [] }
        return stride(from: 0, to: characters.count, by: capacity).map {
            String(characters[$0 ..< min($0 + capacity, characters.count)])
        }
    }

    /// 竖排卡用语的单段截断：超 max 字补省略号。
    static func truncate(_ text: String, maxLength: Int) -> String {
        text.count <= maxLength ? text : String(text.prefix(maxLength)) + "…"
    }
}

/// Aesthetic Quote Card Generator Modal View (WeChat Read & Apple Books style)
struct QuoteCardView: View {
    let highlight: Highlight
    let book: EPUBBook?
    let onClose: () -> Void

    @State private var selectedTheme: QuoteCardTheme = .sepia
    @State private var includeThought: Bool = true
    @State private var textFormat: ShareTextFormat = .quoteWithThought
    @State private var shareToast: String? = nil
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
        .overlay(alignment: .top) {
            shareToastView
        }
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

    // MARK: 古典竖排卡（真竖排逐字成列 · 朱丝栏批注分隔 · 3:4 版心 · 朱砂印章题跋）
    @ViewBuilder
    private var classicalVerticalCard: some View {
        verticalCardBody
            .padding(18)
            .frame(width: 420, height: 560)
            .background(verticalCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .environment(\.layoutDirection, .rightToLeft)
    }

    private var verticalCardBackground: some View {
        LinearGradient(
            colors: selectedTheme.bgColors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(
            // 朱丝栏内衬框：细朱线内缩 6pt，宣纸信笺的界格感
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(selectedTheme.accentColor.opacity(0.28), lineWidth: 0.6)
                .padding(6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(hex: "#A83226").opacity(0.22), lineWidth: 0.8)
        )
    }

    @ViewBuilder
    private var verticalCardBody: some View {
        let quoteBody = QuoteCardLayout.truncate(highlight.text, maxLength: 144)
        let quoteColumns = QuoteCardLayout.verticalColumns(quoteBody, capacity: 16)
        let thoughtBody = includeThought
            ? QuoteCardLayout.truncate(highlight.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", maxLength: 120)
            : ""
        let thoughtColumns = QuoteCardLayout.verticalColumns(thoughtBody, capacity: 22)
        let cardTitle = highlight.bookTitle.isEmpty ? (book?.title ?? "未知书目") : highlight.bookTitle
        let creditAuthor = (book?.author).flatMap { $0.isEmpty ? nil : $0 } ?? highlight.wechatAuthor
        let creditAuthorBody = QuoteCardLayout.truncate(creditAuthor ?? "", maxLength: 10)
        let creditChapter = QuoteCardLayout.truncate(highlight.chapterTitle, maxLength: 12)

        HStack(alignment: .top, spacing: 12) {
            // —— 结构顺序 = 视觉右→左（layoutDirection .rightToLeft）——

            // 开卷装饰（视觉最右）：句首引线 + 「書」
            VStack(spacing: 8) {
                Text("“")
                    .font(.system(size: 26, weight: .bold, design: .serif))
                    .foregroundStyle(selectedTheme.accentColor.opacity(0.5))
                Rectangle()
                    .fill(selectedTheme.accentColor.opacity(0.4))
                    .frame(width: 1.1, height: 54)
                Text("書")
                    .font(.system(size: 14, weight: .medium, design: .serif))
                    .foregroundStyle(selectedTheme.accentColor.opacity(0.75))
            }

            // 引文正文（右起逐字竖列）
            verticalColumnStack(quoteColumns, font: .system(size: 16.5, design: .serif), gap: 7)

            // 思考批注（朱丝线分隔 + 朱点导引 + 弱化小字）
            if !thoughtColumns.isEmpty {
                Rectangle()
                    .fill(selectedTheme.accentColor.opacity(0.35))
                    .frame(width: 0.8, height: 210)
                    .padding(.top, 6)
                VStack(alignment: .center, spacing: 8) {
                    Circle()
                        .fill(selectedTheme.accentColor.opacity(0.55))
                        .frame(width: 5, height: 5)
                    verticalColumnStack(thoughtColumns, font: .system(size: 11, design: .serif), gap: 4.5, color: selectedTheme.textColor.opacity(0.8))
                }
            }

            // 落款题跋（视觉最左）：朱砂印章 + 书名/作者/章节竖排小字
            VStack(spacing: 12) {
                Spacer()
                VStack(spacing: 2) {
                    Text("读")
                        .font(.system(size: 11.5, weight: .semibold, design: .serif))
                        .foregroundStyle(.white)
                    Text("书")
                        .font(.system(size: 11.5, weight: .semibold, design: .serif))
                        .foregroundStyle(.white)
                }
                .frame(width: 30, height: 58)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color(hex: "#A83226").opacity(0.9))
                )
                .shadow(color: Color(hex: "#A83226").opacity(0.25), radius: 2.5, x: 0, y: 1)

                HStack(alignment: .top, spacing: 7) {
                    verticalColumnStack(
                        QuoteCardLayout.verticalColumns(QuoteCardLayout.truncate(cardTitle, maxLength: 24), capacity: 12),
                        font: .system(size: 9.5, design: .serif),
                        gap: 3,
                        color: selectedTheme.secondaryColor.opacity(0.75)
                    )
                    if !creditAuthorBody.isEmpty {
                        verticalColumnStack(
                            QuoteCardLayout.verticalColumns(creditAuthorBody, capacity: 10),
                            font: .system(size: 9, design: .serif),
                            gap: 3,
                            color: selectedTheme.secondaryColor.opacity(0.6)
                        )
                    }
                    if !creditChapter.isEmpty {
                        verticalColumnStack(
                            QuoteCardLayout.verticalColumns(creditChapter, capacity: 12),
                            font: .system(size: 9, design: .serif),
                            gap: 3,
                            color: selectedTheme.secondaryColor.opacity(0.6)
                        )
                    }
                }
            }
        }
    }

    /// 一列竖字：逐字 Text 自上而下
    @ViewBuilder
    private func verticalColumnStack(_ columns: [String], font: Font, gap: CGFloat, color: Color? = nil) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                VStack(spacing: gap) {
                    ForEach(Array(column.enumerated()), id: \.offset) { _, char in
                        Text(String(char))
                            .font(font)
                            .foregroundStyle(color ?? selectedTheme.textColor)
                            .fixedSize()
                    }
                }
            }
        }
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

    // MARK: - Bottom Action Bar（icon-only 紧凑工具行，说明藏进 hover tooltip 与顶部 toast）
    private var actionBar: some View {
        HStack(spacing: 10) {
            Spacer()

            // 分享到 X（主路径）：文字进发帖窗、卡片图自动进剪贴板
            Button {
                shareToX()
            } label: {
                Text("X")
                    .font(.system(size: 15, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color(nsColor: .controlAccentColor))
                    )
            }
            .buttonStyle(.plain)
            .help("分享到 X：打开发帖窗，卡片图自动进剪贴板，⌘V 粘贴图文")

            CardIconButton(
                systemImage: "square.and.arrow.up",
                helpText: "系统分享菜单（邮件、消息、其他客户端）",
                action: { showSystemShare = true }
            )

            textFormatMenu

            CardIconButton(
                systemImage: "doc.on.doc",
                helpText: "复制卡片图片",
                action: { copyCardImage() }
            )

            CardIconButton(
                systemImage: "arrow.down.circle",
                helpText: "保存高清 PNG",
                action: { saveCardPNG() }
            )

            Spacer()
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

    /// 文字版菜单：点击主体直接复制当前格式；侧下拉切换引文/思考组合格式
    private var textFormatMenu: some View {
        Menu(
            content: {
                Picker("文字格式", selection: $textFormat) {
                    ForEach(ShareTextFormat.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }
            },
            label: {
                Image(systemName: "text.quote")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.75))
                    .frame(width: 38, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )
            },
            primaryAction: {
                copyShareText()
            }
        )
        .menuStyle(.button)
        .fixedSize()
        .help("复制文字版（点击直接复制；下拉切换格式）")
    }

    // MARK: - Toast（动作反馈：顶部轻量胶囊，替代按钮内变文字）

    @ViewBuilder
    private var shareToastView: some View {
        if let shareToast {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                Text(shareToast)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(Color(hex: "#1F9E51"))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @MainActor
    private func flash(_ message: String) {
        withAnimation(.easeOut(duration: 0.18)) { shareToast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            withAnimation(.easeIn(duration: 0.18)) { shareToast = nil }
        }
    }

    // MARK: - Share Actions

    @MainActor
    private func shareToX() {
        // 「包含思考」勾选时文字版也带上思考；未勾选走纯引文
        let format: ShareTextFormat = (includeThought && hasThought) ? .quoteWithThought : .quoteOnly
        guard let image = generateCardNSImage() else {
            flash("卡片图生成失败，请重试")
            return
        }
        let note = SocialShare.shareToX(
            text: ShareTextComposer.composeText(format: format, highlight: highlight, book: book),
            image: image
        )
        flash(note)
    }

    @MainActor
    private func copyShareText() {
        SocialShare.copyText(
            ShareTextComposer.composeText(format: textFormat, highlight: highlight, book: book)
        )
        flash("文字版已复制（\(textFormat.displayName)）")
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

    // MARK: - Image Rendering Actions

    @MainActor
    private func generateCardNSImage() -> NSImage? {
        // 3x 超采样导出，卡片背景已在源视图内含纯色兜底（不透明），
        // 导出内容不含投影 —— 分享白底场景不带脏边
        QuoteCardImageRenderer.render(cardContent)
    }

    @MainActor
    private func copyCardImage() {
        guard let image = generateCardNSImage() else {
            flash("卡片图生成失败，请重试")
            return
        }
        SocialShare.copyImage(image)
        flash("卡片图已复制")
    }

    @MainActor
    private func saveCardPNG() {
        guard let image = generateCardNSImage(),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            flash("卡片图生成失败，请重试")
            return
        }

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.png]
        savePanel.nameFieldStringValue = "《\(highlight.bookTitle.isEmpty ? (book?.title ?? "金句") : highlight.bookTitle)》金句卡片.png"
        savePanel.title = "保存金句卡片图片"

        if savePanel.runModal() == .OK, let targetURL = savePanel.url {
            try? pngData.write(to: targetURL)
            flash("已保存高清 PNG")
        }
    }
}

/// 紧凑 icon-only 工具按钮：hover 反馈 + tooltip 说明
private struct CardIconButton: View {
    let systemImage: String
    let helpText: String
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.primary.opacity(hovered ? 0.95 : 0.72))
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(hovered ? 0.12 : 0.05))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(helpText)
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
