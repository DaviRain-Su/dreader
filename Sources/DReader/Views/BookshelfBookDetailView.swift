import SwiftUI

/// 原生书籍详情：封面、元数据和操作均来自当前真实书籍。
struct BookshelfBookDetailView: View {
    let book: EPUBBook
    let onContinue: () -> Void
    var onOpenXRay: (() -> Void)? = nil
    var onResetProgress: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    var chineseScriptMode: ChineseScriptMode = .original

    @Environment(\.dismiss) private var dismiss
    @State private var cover: NSImage?

    private var title: String {
        ChineseScriptConverter.convert(book.title, mode: chineseScriptMode)
    }
    private var author: String {
        ChineseScriptConverter.convert(book.author, mode: chineseScriptMode)
    }

    var body: some View {
        ZStack {
            Color(hex: "#F4F2ED").ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button("关闭") { dismiss() }
                        .keyboardShortcut(.escape, modifiers: [])
                        .buttonStyle(.bordered)
                    Spacer()
                    Label("DReader · 藏书长廊", systemImage: "books.vertical")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(hex: "#1F3FB0"))
                    Spacer()
                    Menu {
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
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 17))
                    }
                    .menuStyle(.borderlessButton)
                    .accessibilityLabel("更多书籍操作")
                }
                .padding(.horizontal, 28)
                .frame(height: 68)

                ScrollView {
                    HStack(alignment: .center, spacing: 42) {
                        coverView
                            .frame(width: 238, height: 360)
                            .shadow(color: .black.opacity(0.2), radius: 20, y: 12)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 18) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("书籍详情")
                                    .font(.system(size: 11, weight: .semibold))
                                    .tracking(1.2)
                                    .foregroundStyle(Color(hex: "#1F3FB0"))
                                Text(title)
                                    .font(.system(size: 38, weight: .regular, design: .serif))
                                    .foregroundStyle(Color(hex: "#141414"))
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(author)
                                    .font(.system(size: 16, design: .serif))
                                    .foregroundStyle(Color(hex: "#6D6A63"))
                            }

                            VStack(alignment: .leading, spacing: 7) {
                                Label("\(book.chapters.count) 章节", systemImage: "list.bullet")
                                if let chapter = book.currentChapter {
                                    Label("当前：\(chapter.title)", systemImage: "bookmark")
                                        .lineLimit(2)
                                }
                                Label("已读 \(Int(book.progress * 100))%", systemImage: "chart.bar")
                            }
                            .font(.system(size: 12))
                            .foregroundStyle(Color(hex: "#6D6A63"))

                            Text(book.bookDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                 ? "本书暂未提供简介。可以从当前章节继续阅读，或打开全书透视查看人物与主题。"
                                 : book.bookDescription)
                                .font(.system(size: 15, design: .serif))
                                .foregroundStyle(Color(hex: "#141414"))
                                .lineSpacing(6)
                                .frame(maxWidth: 440, alignment: .leading)

                            Button(action: onContinue) {
                                Label(book.currentChapterIndex > 0 ? "继续阅读" : "开始阅读",
                                      systemImage: "book.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                    .frame(minWidth: 148)
                                    .padding(.vertical, 10)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color(hex: "#1F3FB0"))
                            .padding(.top, 6)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 42)
                    .padding(.vertical, 32)
                    .frame(maxWidth: 940)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .accessibilityElement(children: .contain)
        .task(id: book.coverImageURL) {
            cover = nil
            guard let url = book.coverImageURL else { return }
            // 同 BookshelfGalleryBookView：经 CoverImageCache.image(for:) 异步入口。
            let image = await CoverImageCache.shared.image(for: url)
            guard !Task.isCancelled else { return }
            cover = image
        }
    }

    private var coverView: some View {
        ZStack {
            if let cover {
                Image(nsImage: cover)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(colors: [Color(hex: "#33456A"), Color(hex: "#17223B")],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(spacing: 18) {
                    Text(title)
                        .font(.system(size: 25, design: .serif))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    Text(author)
                        .font(.system(size: 13, design: .serif))
                        .foregroundStyle(Color.white.opacity(0.74))
                }
                .padding(22)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}
