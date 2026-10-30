import SwiftUI

/// 单本书的书脊与封面；不把固定尺寸的经典卡片硬塞进长廊。
struct BookshelfGalleryBookView: View {
    let book: EPUBBook
    let openness: Double
    let isHovered: Bool
    let spineWidth: CGFloat
    let coverWidth: CGFloat
    let height: CGFloat
    var chineseScriptMode: ChineseScriptMode = .original
    var reduceMotion = false
    let onOpen: () -> Void
    var onOpenXRay: (() -> Void)? = nil
    var onResetProgress: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    @State private var loadedCover: NSImage?

    private var title: String {
        ChineseScriptConverter.convert(book.title, mode: chineseScriptMode)
    }
    private var author: String {
        ChineseScriptConverter.convert(book.author, mode: chineseScriptMode)
    }
    private var palette: (start: Color, end: Color) {
        let palettes: [(start: Color, end: Color)] = [
            (Color(hex: "#263D38"), Color(hex: "#13231F")),
            (Color(hex: "#33456A"), Color(hex: "#17223B")),
            (Color(hex: "#68483A"), Color(hex: "#32251F")),
            (Color(hex: "#54475F"), Color(hex: "#29232F")),
            (Color(hex: "#5A5B49"), Color(hex: "#2C2E22"))
        ]
        let checksum = book.id.uuidString.utf8.reduce(0) { $0 &+ Int($1) }
        return palettes[checksum % palettes.count]
    }

    var body: some View {
        Button(action: onOpen) {
            ZStack {
                if openness < 0.5 {
                    spine
                        .frame(width: spineWidth, height: height)
                        .rotation3DEffect(
                            .degrees(reduceMotion ? 0 : -46 * openness),
                            axis: (x: 0, y: 1, z: 0), perspective: 0.65
                        )
                } else {
                    cover
                        .frame(width: coverWidth, height: height)
                        .rotation3DEffect(
                            .degrees(reduceMotion ? 0 : 46 * (1 - openness)),
                            axis: (x: 0, y: 1, z: 0), perspective: 0.65
                        )
                }
            }
            .frame(width: spineWidth + (coverWidth - spineWidth) * CGFloat(openness), height: height)
            .rotation3DEffect(
                .degrees(reduceMotion ? 0 : -7 * openness),
                axis: (x: 0, y: 1, z: 0), perspective: 0.7
            )
            .rotationEffect(.degrees(reduceMotion ? 0 : -4.5 * openness))
            .shadow(color: .black.opacity(0.16 + openness * 0.16),
                    radius: 5 + openness * 18, y: 4 + openness * 14)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)，作者 \(author)")
        .accessibilityValue("已读 \(Int(book.progress * 100))%")
        .accessibilityHint(openness > 0.5 ? "打开书籍详情" : "选择这本书")
        .help(openness > 0.5 ? "打开书籍详情" : "选择 \(title)")
        .contextMenu {
            Button("查看书籍详情", action: onOpen)
            if let onOpenXRay {
                Button("查看全书透视 (X-Ray)", action: onOpenXRay)
            }
            if let onResetProgress {
                Button("重置本书阅读进度", action: onResetProgress)
            }
            if let onDelete {
                Divider()
                Button("从书架中移除", role: .destructive, action: onDelete)
            }
        }
        .task(id: book.coverImageURL) {
            loadedCover = nil
            guard let url = book.coverImageURL else { return }
            // loadImage 回调标注 @MainActor；经 CoverImageCache.image(for:) 异步入口，
            // NSImage 在主 actor 闭包内交接，避免 Swift 6.0 的 sending 检查。
            let image = await CoverImageCache.shared.image(for: url)
            guard !Task.isCancelled else { return }
            loadedCover = image
        }
    }

    private var spine: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 2)
                .fill(LinearGradient(colors: [palette.start, palette.end],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: 2)
                .stroke(Color.white.opacity(0.18), lineWidth: 0.7)
            VStack(spacing: 8) {
                if let loadedCover {
                    Image(nsImage: loadedCover)
                        .resizable()
                        .scaledToFill()
                        .frame(width: max(20, spineWidth - 8), height: height * 0.16)
                        .clipShape(RoundedRectangle(cornerRadius: 1.5))
                } else {
                    Image(systemName: "book.closed")
                        .font(.system(size: max(11, spineWidth * 0.48)))
                        .foregroundStyle(Color.white.opacity(0.78))
                        .frame(height: height * 0.16)
                }
                Text(title)
                    .font(.system(size: 10, weight: .medium, design: .serif))
                    .foregroundStyle(Color.white.opacity(0.94))
                    .lineLimit(1)
                    .frame(width: height * 0.52)
                    .rotationEffect(.degrees(90))
                    .frame(maxHeight: .infinity)
                Text("DREADER")
                    .font(.system(size: 5.5, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(Color.white.opacity(0.58))
                    .rotationEffect(.degrees(90))
                    .frame(height: 24)
            }
            .padding(.vertical, 9)
        }
        .accessibilityHidden(true)
    }

    private var cover: some View {
        ZStack {
            if let loadedCover {
                Image(nsImage: loadedCover)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(colors: [palette.start, palette.end],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(spacing: 13) {
                    Text("DREADER · 藏书")
                        .font(.system(size: 8, weight: .semibold))
                        .tracking(1.6)
                        .foregroundStyle(Color.white.opacity(0.62))
                    Text(title)
                        .font(.system(size: 20, weight: .regular, design: .serif))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                        .minimumScaleFactor(0.75)
                    Rectangle()
                        .fill(Color.white.opacity(0.35))
                        .frame(width: 34, height: 1)
                    Text(author)
                        .font(.system(size: 10, design: .serif))
                        .foregroundStyle(Color.white.opacity(0.76))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Spacer()
                    Text("\(book.chapters.count) 章节")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.64))
                }
                .padding(18)
            }
            RoundedRectangle(cornerRadius: 3)
                .stroke(Color.white.opacity(0.22), lineWidth: 0.8)
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .accessibilityHidden(true)
    }
}
