import SwiftUI

/// 读完复盘弹窗：合上最后一页时的一次性庆祝卡。
/// 汇总本书全部沉淀——划线、想法、生词、书签、章节分布、主打引文。
/// 设计纪律：无彩 chrome，彩色只属数据本身（划线色块、生词蓝）。
struct FinishCardView: View {
    let snapshot: FinishSnapshot
    let onClose: () -> Void
    /// 「再来一次 Mastery 复习」等后续行动的回调（可空）
    var onStartReview: (() -> Void)? = nil

    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    statsGrid
                    if let quote = snapshot.featuredQuote {
                        featuredQuoteCard(quote)
                    }
                    if !snapshot.topChapters.isEmpty {
                        chapterDistribution
                    }
                    if snapshot.thoughtCount > 0 {
                        thoughtsDigest
                    }
                }
                .padding(24)
            }

            Divider().opacity(0.2)
            footerBar
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 540, idealHeight: 620, maxHeight: 700)
        .background(.ultraThinMaterial)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 18)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85).delay(0.05)) {
                appeared = true
            }
        }
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("读完了")
                        .font(.system(size: 26, weight: .bold, design: .serif))
                    Text("《\(snapshot.bookTitle)》\(snapshot.author.isEmpty ? "" : " · \(snapshot.author)")")
                        .font(.system(size: 13.5))
                        .foregroundStyle(.secondary)
                    Text("共 \(snapshot.chapterCount) 章\(spanText)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary.opacity(0.8))
                }
                Spacer()
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var spanText: String {
        guard let span = snapshot.spanDays, span >= 1 else { return "" }
        return " · 印记跨越 \(span) 天"
    }

    // MARK: - 数据四格

    private var statsGrid: some View {
        HStack(spacing: 12) {
            statTile(value: "\(snapshot.highlightCount)", label: "划线", icon: "highlighter", color: Color(hex: "#FFE066"))
            statTile(value: "\(snapshot.thoughtCount)", label: "想法", icon: "thought.bubble.fill", color: Color(hex: "#B5E48C"))
            statTile(value: "\(snapshot.vocabularyCount)", label: "生词", icon: "character.book.closed.fill", color: Color(hex: "#A5D8FF"))
            statTile(value: "\(snapshot.bookmarkCount)", label: "书签", icon: "bookmark.fill", color: Color(hex: "#FFC9A3"))
        }
    }

    private func statTile(value: String, label: String, icon: String, color: Color) -> some View {
        VStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 21, weight: .bold, design: .rounded))
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 主打引文

    private func featuredQuoteCard(_ quote: Highlight) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "quote.opening")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
                Text(snapshot.thoughtCount > 0 ? "印象最深的一条想法" : "印象最深的一条划线")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(quote.chapterTitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary.opacity(0.75))
                    .lineLimit(1)
            }
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color(hex: quote.colorHex).opacity(0.85))
                .frame(width: 34, height: 3)
            Text(quote.text)
                .font(.system(size: 14, weight: .medium, design: .serif))
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
            if let note = quote.note, !note.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.25))
                        .frame(width: 2)
                    Text(note)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 章节分布

    private var chapterDistribution: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("印记最密的章节")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
            let maxCount = snapshot.topChapters.first?.count ?? 1
            ForEach(Array(snapshot.topChapters.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 10) {
                    Text(item.title)
                        .font(.system(size: 11.5))
                        .lineLimit(1)
                        .frame(width: 150, alignment: .leading)
                        .truncationMode(.tail)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.primary.opacity(0.05))
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.primary.opacity(0.45))
                                .frame(width: max(6, geo.size.width * CGFloat(item.count) / CGFloat(maxCount)))
                        }
                    }
                    .frame(height: 6)
                    Text("\(item.count)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, alignment: .trailing)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 想法摘录

    private var thoughtsDigest: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("你的想法")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(snapshot.thoughtHighlights.prefix(3).enumerated()), id: \.element.id) { _, h in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(Color(hex: h.colorHex).opacity(0.9))
                        .frame(width: 7, height: 7)
                        .padding(.top, 4)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(h.note ?? "")
                            .font(.system(size: 12))
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("「\(h.text.prefix(40))\(h.text.count > 40 ? "…" : "")」")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary.opacity(0.7))
                            .lineLimit(1)
                    }
                }
            }
            if snapshot.thoughtCount > 3 {
                Text("…以及另外 \(snapshot.thoughtCount - 3) 条")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary.opacity(0.65))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 底栏

    private var footerBar: some View {
        HStack(spacing: 14) {
            if snapshot.highlightCount > 0 {
                Button {
                    onClose()
                    onStartReview?()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "brain.head.profile")
                            .font(.system(size: 11, weight: .semibold))
                        Text("复习本书划线")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.82))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            Spacer()

            Text("成就已记入书斋")
                .font(.system(size: 11))
                .foregroundStyle(.secondary.opacity(0.7))

            Button {
                onClose()
            } label: {
                Text("合上")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.8))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }
}
