import SwiftUI

struct RealisticBookItemView: View {
    let book: EPUBBook
    let onOpen: () -> Void
    var onOpenXRay: (() -> Void)? = nil
    var onResetProgress: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    var chineseScriptMode: ChineseScriptMode = .original

    @State private var isHovered: Bool = false
    @State private var loadedCover: NSImage? = nil

    // Color theme per book for fallback
    private var coverTheme: (bgStart: String, bgEnd: String, gold: String, accent: String) {
        let t = book.title.lowercased()
        if t.contains("瓦尔登") || t.contains("walden") {
            return ("#1B382B", "#0D1E16", "#ECC376", "#52B788") // Forest Emerald
        } else if t.contains("小王子") || t.contains("prince") {
            return ("#18233C", "#0B1120", "#F3D084", "#64DFDF") // Midnight Sapphire
        } else if t.contains("朝花") || t.contains("鲁迅") {
            return ("#481923", "#270B12", "#E8C27E", "#E76F51") // Antique Crimson
        } else {
            return ("#282C34", "#181A1F", "#DFBA73", "#98C379") // Classic Leather
        }
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(spacing: 0) {
                ZStack(alignment: .bottomLeading) {
                    // Contact Shadow on the shelf
                    Ellipse()
                        .fill(Color.black.opacity(isHovered ? 0.35 : 0.48))
                        .frame(width: 136, height: 16)
                        .blur(radius: isHovered ? 6 : 3)
                        .offset(y: isHovered ? 14 : 8)

                    // The 3D Book
                    ZStack(alignment: .leading) {
                        // 1. Right Page Edge Block (Simulating paper block thickness)
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color(hex: "#ECE6D8"), Color(hex: "#D6CEBC"), Color(hex: "#E5DEC9")],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: 142, height: 204)
                            .offset(x: 4)
                            .overlay(
                                // Fine vertical paper stripes on right edge
                                HStack {
                                    Spacer()
                                    Rectangle()
                                        .fill(Color.black.opacity(0.12))
                                        .frame(width: 1)
                                    Rectangle()
                                        .fill(Color.black.opacity(0.08))
                                        .frame(width: 1)
                                }
                                .padding(.trailing, 2)
                            )

                        // 2. Main Hardcover
                        if let img = loadedCover {
                            // Real Book Cover Image (from EPUB file, like Apple Books)
                            ZStack {
                                Image(nsImage: img)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 140, height: 204)
                                    .clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                                // Subtle Leather/Canvas Grain Edge Stroke
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .stroke(Color.white.opacity(0.18), lineWidth: 0.8)

                                // 3. Spine Fold / Cloth Groove (书脊立体压痕与光影)
                                HStack {
                                    LinearGradient(
                                        colors: [
                                            Color.white.opacity(0.22),
                                            Color.black.opacity(0.38),
                                            Color.white.opacity(0.1),
                                            Color.clear
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                    .frame(width: 14)

                                    Spacer()
                                }

                                // Left Spine Hinge indentation line
                                HStack {
                                    Rectangle()
                                        .fill(Color.black.opacity(0.42))
                                        .frame(width: 1)
                                        .offset(x: 14)
                                    Spacer()
                                }
                            }
                            .frame(width: 140, height: 204)
                        } else {
                            // Fallback: Elegant Embossed Synthetic Leather Cover
                            ZStack {
                                // Cover Gradient
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: [Color(hex: coverTheme.bgStart), Color(hex: coverTheme.bgEnd)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )

                                // Subtle Leather/Canvas Texture Grain
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .stroke(Color.white.opacity(0.08), lineWidth: 1)

                                // Embossed Golden Filigree Frame (烫金双线框)
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .stroke(Color(hex: coverTheme.gold).opacity(0.45), lineWidth: 1)
                                    .padding(8)

                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .stroke(Color(hex: coverTheme.gold).opacity(0.25), lineWidth: 0.5)
                                    .padding(11)

                                // Cover Content
                                VStack(spacing: 8) {
                                    // Top Ornamental Crest
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 13))
                                        .foregroundStyle(Color(hex: coverTheme.gold).opacity(0.75))
                                        .padding(.top, 20)

                                    Spacer()

                                    // Book Title
                                    Text(ChineseScriptConverter.convert(book.title, mode: chineseScriptMode))
                                        .font(.system(size: 14, weight: .bold, design: .serif))
                                        .foregroundStyle(Color(hex: coverTheme.gold))
                                        .multilineTextAlignment(.center)
                                        .lineLimit(3)
                                        .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
                                        .padding(.horizontal, 14)

                                    // Divider Ornament
                                    Rectangle()
                                        .fill(Color(hex: coverTheme.gold).opacity(0.5))
                                        .frame(width: 36, height: 1)

                                    // Author
                                    Text(ChineseScriptConverter.convert(book.author, mode: chineseScriptMode))
                                        .font(.system(size: 11, weight: .medium, design: .serif))
                                        .foregroundStyle(Color(hex: coverTheme.gold).opacity(0.85))
                                        .lineLimit(1)
                                        .padding(.horizontal, 12)

                                    Spacer()

                                    // Chapter Count Plaque
                                    Text("\(book.chapters.count) 章节")
                                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(Color(hex: coverTheme.gold).opacity(0.65))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 2)
                                        .background(Color.black.opacity(0.25))
                                        .clipShape(Capsule())
                                        .padding(.bottom, 16)
                                }

                                // 3. Spine Fold / Cloth Groove (书脊立体压痕)
                                HStack {
                                    LinearGradient(
                                        colors: [
                                            Color.white.opacity(0.18),
                                            Color.black.opacity(0.25),
                                            Color.white.opacity(0.08),
                                            Color.clear
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                    .frame(width: 14)

                                    Spacer()
                                }

                                // Left Spine Hinge indentation line
                                HStack {
                                    Rectangle()
                                        .fill(Color.black.opacity(0.35))
                                        .frame(width: 1)
                                        .offset(x: 14)
                                    Spacer()
                                }
                            }
                            .frame(width: 140, height: 204)
                        }
                    }

                    // 4. Bookmark Ribbon (丝绸书签缎带) hanging from bottom
                    if book.progress > 0 {
                        BookmarkRibbonView(progress: book.progress)
                            .offset(x: 28, y: 16)
                    }

                    // 5. Progress Badge Pill on Top Right
                    if isHovered || book.progress > 0 {
                        HStack {
                            Spacer()
                            Text(book.progress > 0 ? "已读 \(Int(book.progress * 100))%" : "未读")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.black.opacity(0.68))
                                .clipShape(Capsule())
                                .shadow(radius: 2)
                                .padding(8)
                        }
                        .frame(width: 140, height: 204, alignment: .topTrailing)
                    }
                }
                // 统一书脊悬浮动效：抬升 + 轻微放大 + 接触影随动（全书架唯一节奏）
                .offset(y: isHovered ? -8 : 0)
                .scaleEffect(isHovered ? 1.025 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isHovered)
            }
        }
        .buttonStyle(.plain)
        .task(id: book.coverImageURL) {
            loadedCover = nil
            guard let url = book.coverImageURL else { return }
            let image = await CoverImageCache.shared.image(for: url)
            guard !Task.isCancelled else { return }
            loadedCover = image
        }
        .onHover { isHovered = $0 }
        .contextMenu {
            Button {
                onOpen()
            } label: {
                Label("打开阅读", systemImage: "book.fill")
            }

            if let onOpenXRay = onOpenXRay {
                Button {
                    onOpenXRay()
                } label: {
                    Label("查看全书透视 (X-Ray)", systemImage: "atom")
                }
            }

            Divider()

            if let onResetProgress = onResetProgress {
                Button {
                    onResetProgress()
                } label: {
                    Label("重置本书阅读进度", systemImage: "arrow.counterclockwise")
                }
            }

            Divider()

            if let onDelete = onDelete {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("从书架中移除", systemImage: "trash")
                }
            }
        }
    }
}

/// A realistic silk bookmark ribbon hanging from the bottom of the book
private struct BookmarkRibbonView: View {
    let progress: Double

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [Color(hex: "#C9184A"), Color(hex: "#A4133C")],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 14, height: 22)
                .shadow(color: .black.opacity(0.3), radius: 2, x: 1, y: 2)

            // Ribbon V-notch cut
            RibbonNotchShape()
                .fill(Color(hex: "#A4133C"))
                .frame(width: 14, height: 6)
        }
    }
}

private struct RibbonNotchShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
