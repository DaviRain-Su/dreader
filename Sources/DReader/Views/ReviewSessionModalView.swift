import SwiftUI
import AppKit

/// Daily Mastery Review — resurfacing due highlights WeChat-Read style, with optional
/// AI deep-questioning. Flip-card flow: prompt → reveal → self-graded recall (0..5 style
/// lanes: 还记得 / 有点模糊 / 忘记了), which feeds the 7/14/28-day half-life scheduler.
struct ReviewSessionModalView: View {
    @Bindable var viewModel: ReaderViewModel
    let onClose: () -> Void

    @State private var deck: [LibraryDatabase.DueReviewCard] = []
    @State private var currentIndex: Int = 0
    @State private var isRevealed: Bool = false
    @State private var reviewedCount: Int = 0
    @State private var sessionFinished: Bool = false
    @State private var aiFollowup: String = ""
    @State private var aiAsking: Bool = false
    @State private var dismissedAIAnswer: String? = nil

    private struct LaneMark {
        let symbol: String
        let label: String
        init(level: Int) {
            switch level {
            case 0: symbol = "_seedling"; label = "新卡"
            case 1: symbol = "leaf"; label = "7天期"
            case 2: symbol = "mountain.2dome"; label = "14天期"
            default: symbol = "sun.max"; label = "28天期"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().opacity(0.25)
            if sessionFinished {
                completionView
            } else if let card = deck.first {
                flashCardView(card)
            } else {
                emptyDeckView
            }
        }
        .frame(minWidth: 640, minHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: loadDeck)
        .overlay(aiQuestionOverlay)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "brain.filled.head.profile")
                .font(.system(size: 15))
                .foregroundStyle(Color.primary.opacity(0.75))
            VStack(alignment: .leading, spacing: 1) {
                Text("今日划线 Mastery 复习")
                    .font(.system(size: 14, weight: .bold))
                Text("间隔重现 · 记忆半衰期 7 / 14 / 28 天")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !deck.isEmpty {
                Text("第 \(min(currentIndex + 1, deck.count)) / \(deck.count) 张")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(6)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: - Deck Loading

    private func loadDeck() {
        deck = LibraryDatabase.shared.dueReviewCards(limit: 10)
        reviewedCount = LibraryDatabase.shared.reviewStats().reviewedToday
        currentIndex = 0
        isRevealed = false
        sessionFinished = deck.isEmpty
    }

    // MARK: - Flash Card

    private func flashCardView(_ card: LibraryDatabase.DueReviewCard) -> some View {
        let highlight = card.highlight
        let lane = LaneMark(level: card.masteryLevel)
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Book & chapter context
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color(hex: highlight.colorHex))
                        .frame(width: 8, height: 8)
                    Text("《\(highlight.bookTitle)》")
                        .font(.system(size: 12, weight: .bold, design: .serif))
                        .lineLimit(1)
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(highlight.chapterTitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    sourceBadge(for: highlight)
                    Spacer()
                    HStack(spacing: 3) {
                        Image(systemName: lane.symbol)
                            .font(.system(size: 9))
                        Text(lane.label)
                    }
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(Capsule())
                }

                // Recall prompt
                VStack(alignment: .leading, spacing: 8) {
                    Label("回忆挑战", systemImage: "questionmark.diamond.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.primary.opacity(0.75))
                    Text(recallPrompt(for: highlight))
                        .font(.system(size: 13.5, design: .serif))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                    if let note = highlight.note, !note.isEmpty, isRevealed {
                        HStack(alignment: .top, spacing: 5) {
                            Image(systemName: "thought.bubble")
                                .font(.system(size: 10))
                            Text(note)
                                .font(.system(size: 11.5))
                        }
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .background(Color.primary.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                }
                .padding(14)
                .background(Color.primary.opacity(0.03))
                .clipShape(RoundedRectangle(cornerRadius: 10))

                // The highlight itself (hidden until reveal)
                if isRevealed {
                    VStack(alignment: .leading, spacing: 7) {
                        Label("原划线", systemImage: "highlighter")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color(hex: highlight.colorHex))
                        Text(highlight.text)
                            .font(.system(size: 13.5, design: .serif))
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .background(Color(hex: highlight.colorHex).opacity(0.09))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .transition(.opacity)

                    // AI follow-up button
                    Button {
                        askAIFollowup(for: highlight)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "sparkles")
                            Text(aiAsking ? "正在生成追问..." : "让 AI 深度追问这段划线")
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.75))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(aiAsking)
                }

                // Actions
                HStack {
                    if !isRevealed {
                        Spacer()
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) { isRevealed = true }
                        } label: {
                            Label("想一想 · 揭晓答案", systemImage: "eye.fill")
                                .font(.system(size: 12.5, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 9)
                                .background(Color.primary.opacity(0.8))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    } else {
                        gradeButton("忘记了", color: .red, scoreOf: 1)
                        Spacer()
                        gradeButton("有点模糊", color: .orange, scoreOf: 3)
                        Spacer()
                        gradeButton("完全记得", color: Color(hex: "#07C160"), scoreOf: 5)
                    }
                }
                .padding(.top, 4)
            }
            .padding(18)
        }
        .onChange(of: isRevealed) { _, newValue in
            if !newValue { dismissedAIAnswer = nil }
        }
    }

    private func gradeButton(_ label: String, color: Color, scoreOf: Int) -> some View {
        Button {
            recordGrade(scoreOf: scoreOf)
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(color.opacity(0.12))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(scoreOf == 1 ? "遗忘：降回复习队列（间隔重置）" : scoreOf == 3 ? "模糊：留在当前半衰期通道" : "记住：进入更长半衰期通道")
    }

    // MARK: - 来源徽章（本地划线 / 微信读书 / AI 伴读解读）

    @ViewBuilder
    private func sourceBadge(for highlight: Highlight) -> some View {
        let (icon, label, color): (String, String, Color) = {
            if highlight.isFromWeChatRead {
                return ("quote.bubble.fill", "微信读书", Color(hex: "#07C160"))
            } else if highlight.source == "ai_companion" {
                return ("sparkles", "AI 伴读", Color(hex: "#8E7CC3"))
            } else {
                return ("hand.draw", "本地划线", .orange)
            }
        }()
        HStack(spacing: 2.5) {
            Image(systemName: icon)
                .font(.system(size: 8))
            Text(label)
                .font(.system(size: 9, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(color.opacity(0.1))
        .clipShape(Capsule())
    }

    private func recallPrompt(for highlight: Highlight) -> String {
        if let note = highlight.note, !note.isEmpty {
            return "还记得当时的思考吗？【\(highlight.bookTitle) · \(highlight.chapterTitle)】"
        }
        return "试着回忆你划下这段话时的心情与理由，以及它的核心主张："
    }

    // MARK: - Grading

    private func recordGrade(scoreOf: Int) {
        guard let card = deck.first else { return }
        LibraryDatabase.shared.recordReview(highlightId: card.highlight.id, score: scoreOf)
        reviewedCount += 1
        currentIndex += 1
        isRevealed = false
        aiFollowup = ""
        dismissedAIAnswer = nil
        deck.removeFirst()
        if deck.isEmpty { sessionFinished = true }
    }

    // MARK: - AI Follow-up

    private func askAIFollowup(for highlight: Highlight) {
        aiAsking = true
        aiFollowup = ""
        let question = """
        我之前在这本书《\(highlight.bookTitle)》（\(highlight.chapterTitle)）中划了这段话：
        『\(highlight.text)』
        请假装严格又亲切的导师，就这段内容向我提出一个最关键的追问（用于检验我是否真正理解，而非背诵原文），并附上一句提示方向的启发但不揭示答案。
        """
        viewModel.agentService.sendMessage(
            history: [],
            bookTitle: highlight.bookTitle,
            author: "",
            chapterTitle: highlight.chapterTitle,
            activeQuote: highlight.text,
            userPrompt: question,
            onToken: { token in
                aiFollowup += token
            },
            onComplete: { aiAsking = false },
            onError: { errorMsg in
                aiFollowup = "⚠️ \(errorMsg)"
                aiAsking = false
            }
        )
    }

    @ViewBuilder
    private var aiQuestionOverlay: some View {
        if aiAsking || !aiFollowup.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "sparkles")
                        .foregroundStyle(Color.primary.opacity(0.75))
                    Text("AI 导师追问")
                        .font(.system(size: 12, weight: .bold))
                    Spacer()
                    Button {
                        aiFollowup = ""
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                ScrollView {
                    if aiFollowup.isEmpty {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("正在生成...")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        MarkdownContentView(markdown: aiFollowup)
                    }
                }
            }
            .padding(16)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.25), radius: 18, y: 4)
            .padding(28)
        }
    }

    // MARK: - Empty Deck

    private var emptyDeckView: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 36))
                .foregroundStyle(Color(hex: "#07C160"))
            Text("今日复习任务已完成")
                .font(.system(size: 15, weight: .bold))
            Text("目前没有到期的划线。划线会在 7 / 14 / 28 天后半衰期到期时自动重现。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Text("今日已复习 \(reviewedCount) 张卡")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.75))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    // MARK: - Completion

    private var completionView: some View {
        VStack(spacing: 14) {
            Image(systemName: "brain.filled.head.profile")
                .font(.system(size: 34))
                .foregroundStyle(Color.primary.opacity(0.75))
            Text("本轮 Mastery 复习完成 ✓")
                .font(.system(size: 15, weight: .bold))
            Text("今天共完成 \(reviewedCount) 张卡。记得的卡片将进入更长半衰期通道，忘记的会更快重现。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Button {
                onClose()
            } label: {
                Text("完成")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.8))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}
