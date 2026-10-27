import SwiftUI

/// Apple Books & Fitness style Reading Insights & Streak Achievements Modal
struct ReadingInsightsModalView: View {
    let stats: ReadingStats
    let onClose: () -> Void

    private let weekdays = ["日", "一", "二", "三", "四", "五", "六"]

    /// 知识资产快照（SQLite 真实数据，进入面板时刷新一次）
    @State private var knowledgeSnapshot: KnowledgeSnapshot?

    var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            headerBar

            Divider()
                .opacity(0.2)

            ScrollView {
                VStack(spacing: 20) {
                    // Ring & Streak Highlight Card
                    ringAndStreakCard

                    // 4-Quadrant Stats Grid
                    statsGrid

                    // 7-Day Weekly Chart
                    weeklyActivityChart

                    // 30-Day Activity Heatmap
                    monthHeatmap

                    // Knowledge Asset Panel (SQLite 真实数据)
                    knowledgeAssetSection

                    // Achievement Milestone Badges
                    achievementBadgesSection

                    Spacer(minLength: 16)
                }
                .padding(20)
            }
        }
        .frame(minWidth: 460, idealWidth: 500, maxWidth: 540, minHeight: 480, idealHeight: 640, maxHeight: 720)
        .background(.ultraThinMaterial)
        .task {
            knowledgeSnapshot = KnowledgeSnapshot.load()
        }
    }

    // MARK: - 阅读目标调节

    private func updateDailyGoal(_ newGoal: Int) {
        let clamped = min(max(newGoal, 10), 180)
        guard clamped != stats.dailyGoalMinutes else { return }
        ReadingStatsManager.shared.stats.dailyGoalMinutes = clamped
        ReadingStatsManager.shared.save()
    }

    // MARK: - 知识资产区块

    private var knowledgeAssetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("知识资产")
                    .font(.system(size: 12, weight: .bold))
                Text("本地知识库 · 真实数据")
                    .font(.system(size: 9.5, design: .serif))
                    .foregroundStyle(.tertiary)
                Spacer()
                if let snapshot = knowledgeSnapshot {
                    Text(snapshot.generatedDescription)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            if let snap = knowledgeSnapshot {
                HStack(spacing: 10) {
                    knowledgeTile(title: "划线", value: "\(snap.highlightCount)", icon: "highlighter", color: .yellow)
                    knowledgeTile(title: "思考笔记", value: "\(snap.noteCount)", icon: "bubble.left.and.bubble.right.fill", color: .blue)
                    knowledgeTile(title: "书库", value: "\(snap.bookmarkCount)", icon: "books.vertical.fill", color: .brown)
                    knowledgeTile(title: "记忆卡片", value: "\(snap.scheduledCards)", icon: "brain.head.profile.fill", color: .purple)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("正在读取本地知识库...")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .frame(maxWidth: .infinity)
                .background(Color.primary.opacity(0.03))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private func knowledgeTile(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.primary)
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(color.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Header Bar
    private var headerBar: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "flame.circle.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.orange)

                Text("阅读统计与成就")
                    .font(.system(size: 14, weight: .bold))

                Text("Reading Insights")
                    .font(.system(size: 11, design: .serif))
                    .foregroundStyle(.secondary)
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

    // MARK: - Ring & Streak Card
    private var ringAndStreakCard: some View {
        HStack(spacing: 24) {
            // Apple Fitness Style Concentric Ring
            ZStack {
                // Background Track
                Circle()
                    .stroke(Color.orange.opacity(0.18), lineWidth: 10)
                    .frame(width: 86, height: 86)

                // Progress Arc
                Circle()
                    .trim(from: 0, to: CGFloat(stats.todayProgressRatio))
                    .stroke(
                        LinearGradient(
                            colors: [.orange, Color(hex: "#FF7A00"), Color(hex: "#FFB020")],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                    )
                    .frame(width: 86, height: 86)
                    .rotationEffect(.degrees(-90))

                VStack(spacing: 1) {
                    Image(systemName: "book.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.orange)
                    Text("\(Int(stats.todayProgressRatio * 100))%")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.primary)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Text("今日阅读目标")
                        .font(.system(size: 13, weight: .bold))

                    // 可调目标（10~180 分钟，步进 5）
                    HStack(spacing: 3) {
                        Button {
                            updateDailyGoal(stats.dailyGoalMinutes - 5)
                        } label: {
                            Image(systemName: "minus")
                                .font(.system(size: 8, weight: .bold))
                                .frame(width: 16, height: 16)
                                .background(Color.orange.opacity(0.15))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(stats.dailyGoalMinutes <= 10)

                        Text("\(stats.todayMinutes) / \(stats.dailyGoalMinutes) 分钟")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.orange)

                        Button {
                            updateDailyGoal(stats.dailyGoalMinutes + 5)
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 8, weight: .bold))
                                .frame(width: 16, height: 16)
                                .background(Color.orange.opacity(0.15))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(stats.dailyGoalMinutes >= 180)
                    }
                }

                Text(stats.todayMinutes >= stats.dailyGoalMinutes ? "🎉 已达成今日阅读目标！超凡专注" : "还需阅读 \(stats.dailyGoalMinutes - stats.todayMinutes) 分钟以闭合今日圆环")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    HStack(spacing: 4) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                        Text("连续阅读 \(stats.currentStreakDays) 天")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.orange)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.12))
                    .clipShape(Capsule())

                    Text("保持阅读心流")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            }

            Spacer()
        }
        .padding(16)
        .background(Color.orange.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.orange.opacity(0.2), lineWidth: 0.8)
        )
    }

    // MARK: - 4-Quadrant Stats Grid
    private var statsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            statTile(
                title: "今日已读字数",
                value: "\(stats.todayWords) 字",
                icon: "character.book.closed.fill",
                color: .purple
            )
            statTile(
                title: "累计专注时长",
                value: String(format: "%.1f 小时", Double(stats.totalMinutesRead) / 60.0),
                icon: "timer",
                color: .blue
            )
            statTile(
                title: "累计阅读字数",
                value: String(format: "%.1f 万字", Double(stats.totalWordsRead) / 10000.0),
                icon: "doc.text.fill",
                color: .green
            )
            statTile(
                title: "连续阅读天数",
                value: "\(stats.currentStreakDays) 天",
                icon: "flame.fill",
                color: .orange
            )
        }
    }

    private func statTile(title: String, value: String, icon: String, color: Color) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.15))
                    .frame(width: 32, height: 32)
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(color)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.primary)
            }
            Spacer()
        }
        .padding(10)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - 7-Day Weekly Chart
    private var weeklyActivityChart: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("本周阅读走势")
                    .font(.system(size: 12, weight: .bold))
                Spacer()
                Text("平均 \(stats.weeklyMinutes.reduce(0, +) / 7) 分钟/天")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            let maxVal = max(45, stats.weeklyMinutes.max() ?? 45)
            let currentWeekday = Calendar.current.component(.weekday, from: Date()) - 1

            HStack(alignment: .bottom, spacing: 14) {
                ForEach(0..<7, id: \.self) { idx in
                    let mins = stats.weeklyMinutes.indices.contains(idx) ? stats.weeklyMinutes[idx] : 0
                    let heightRatio = CGFloat(mins) / CGFloat(maxVal)
                    let isToday = (idx == currentWeekday)

                    VStack(spacing: 5) {
                        Text("\(mins)m")
                            .font(.system(size: 8.5, design: .monospaced))
                            .foregroundStyle(isToday ? Color.orange : Color.secondary.opacity(0.7))

                        ZStack(alignment: .bottom) {
                            Capsule()
                                .fill(Color.primary.opacity(0.06))
                                .frame(width: 14, height: 60)

                            Capsule()
                                .fill(isToday ? Color.orange : Color.purple.opacity(0.7))
                                .frame(width: 14, height: max(6, 60 * heightRatio))
                        }

                        Text(weekdays[idx])
                            .font(.system(size: 10, weight: isToday ? .bold : .regular))
                            .foregroundStyle(isToday ? Color.orange : Color.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 4)
        }
        .padding(14)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - 30-Day Activity Heatmap

    private var monthHeatmap: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("近 30 天阅读足迹")
                    .font(.system(size: 12, weight: .bold))
                Spacer()
                Text("本月累计 \(stats.monthTotalMinutes) 分钟 · 日均 \(stats.monthDailyAverage) 分钟")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            let history = stats.dailyHistory ?? []
            let maxVal = max(30, history.max() ?? 30)
            let todayIndex = history.count - 1

            HStack(alignment: .bottom, spacing: 3) {
                ForEach(history.indices, id: \.self) { idx in
                    let mins = history[idx]
                    let ratio = Double(mins) / Double(maxVal)
                    let isToday = idx == todayIndex
                    let barColor: Color = mins == 0
                        ? Color.primary.opacity(0.07)
                        : (isToday ? Color.orange : Color.purple.opacity(0.35 + 0.55 * ratio))

                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(barColor)
                        .frame(height: max(5, 46 * ratio))
                        .frame(maxWidth: .infinity)
                        .help("\(mins) 分钟")
                }
            }
            .frame(height: 50)

            HStack {
                Text("30 天前")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("今天")
                    .font(.system(size: 8.5, weight: isTodayActive ? .bold : .regular))
                    .foregroundStyle(isTodayActive ? Color.orange : Color.secondary)
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var isTodayActive: Bool {
        (stats.dailyHistory?.last ?? 0) > 0
    }

    // MARK: - Achievement Badges
    private var achievementBadgesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("阅读成就殿堂")
                .font(.system(size: 12, weight: .bold))

            HStack(spacing: 10) {
                badgeItem(name: "书香启程", desc: "完成首次阅读", icon: "sparkles", isUnlocked: true)
                badgeItem(name: "破晓晨读", desc: "在清晨静读", icon: "sun.horizon.fill", isUnlocked: true)
                badgeItem(name: "心流三日", desc: "连续阅读3天", icon: "flame.fill", isUnlocked: stats.currentStreakDays >= 3)
                badgeItem(name: "十万字卷", desc: "研读突破10万字", icon: "star.fill", isUnlocked: stats.totalWordsRead >= 100000)
            }
        }
    }

    private func badgeItem(name: String, desc: String, icon: String, isUnlocked: Bool) -> some View {
        VStack(spacing: 5) {
            ZStack {
                Circle()
                    .fill(isUnlocked ? Color.purple.opacity(0.18) : Color.primary.opacity(0.05))
                    .frame(width: 38, height: 38)

                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(isUnlocked ? Color.purple : Color.secondary.opacity(0.5))
            }

            Text(name)
                .font(.system(size: 10, weight: isUnlocked ? .bold : .regular))
                .foregroundStyle(isUnlocked ? Color.primary : Color.secondary)

            Text(desc)
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(Color.primary.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .opacity(isUnlocked ? 1.0 : 0.6)
    }
}

/// 知识资产实时快照（SQLite 真实统计）
struct KnowledgeSnapshot {
    let highlightCount: Int
    let noteCount: Int
    let bookmarkCount: Int
    let scheduledCards: Int

    var generatedDescription: String {
        "共 \(highlightCount + noteCount) 条资产"
    }

    static func load() -> KnowledgeSnapshot {
        let db = LibraryDatabase.shared
        let highlights = db.loadHighlights()
        let bookmarks = db.loadBookmarks()
        return KnowledgeSnapshot(
            highlightCount: highlights.count,
            noteCount: highlights.filter { ($0.note ?? "").isEmpty == false }.count,
            bookmarkCount: bookmarks.count,
            scheduledCards: db.scheduledCardCount()
        )
    }
}
