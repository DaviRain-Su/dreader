import SwiftUI

/// Apple Books & Fitness style Reading Insights & Streak Achievements Modal
struct ReadingInsightsModalView: View {
    let stats: ReadingStats
    let onClose: () -> Void

    private let weekdays = ["日", "一", "二", "三", "四", "五", "六"]

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

                    // Achievement Milestone Badges
                    achievementBadgesSection

                    Spacer(minLength: 16)
                }
                .padding(20)
            }
        }
        .frame(minWidth: 460, idealWidth: 500, maxWidth: 540, minHeight: 480, idealHeight: 560, maxHeight: 620)
        .background(.ultraThinMaterial)
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
                    Text("\(stats.todayMinutes) / \(stats.dailyGoalMinutes) 分钟")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.orange)
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
                title: "历史最佳连续",
                value: "\(max(stats.currentStreakDays, 7)) 天",
                icon: "trophy.fill",
                color: .yellow
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
