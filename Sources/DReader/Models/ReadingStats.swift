import Foundation

/// Records reading duration, streaks, and word counts (Apple Books Reading Insights style)
struct ReadingStats: Codable, Sendable {
    var todayMinutes: Int
    var todayWords: Int
    var currentStreakDays: Int
    var totalMinutesRead: Int
    var totalWordsRead: Int
    var dailyGoalMinutes: Int
    var lastReadDate: Date?
    var weeklyMinutes: [Int] // 7 days: [Sun, Mon, Tue, Wed, Thu, Fri, Sat]

    init(
        todayMinutes: Int = 24,
        todayWords: Int = 8500,
        currentStreakDays: Int = 3,
        totalMinutesRead: Int = 340,
        totalWordsRead: Int = 68000,
        dailyGoalMinutes: Int = 30,
        lastReadDate: Date? = Date(),
        weeklyMinutes: [Int] = [15, 25, 40, 30, 20, 35, 24]
    ) {
        self.todayMinutes = todayMinutes
        self.todayWords = todayWords
        self.currentStreakDays = currentStreakDays
        self.totalMinutesRead = totalMinutesRead
        self.totalWordsRead = totalWordsRead
        self.dailyGoalMinutes = dailyGoalMinutes
        self.lastReadDate = lastReadDate
        self.weeklyMinutes = weeklyMinutes
    }

    var todayProgressRatio: Double {
        guard dailyGoalMinutes > 0 else { return 1.0 }
        return min(1.0, Double(todayMinutes) / Double(dailyGoalMinutes))
    }
}
