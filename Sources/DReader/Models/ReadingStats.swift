import Foundation

/// 阅读统计模型：每分钟真实累计 + 按日历史记录
struct ReadingStats: Codable, Sendable {
    var todayMinutes: Int
    var todayWords: Int
    var currentStreakDays: Int
    var totalMinutesRead: Int
    var totalWordsRead: Int
    var dailyGoalMinutes: Int
    var lastReadDate: Date?
    var weeklyMinutes: [Int] // 7 days: [Sun, Mon, Tue, Wed, Thu, Fri, Sat]
    /// 最近 30 天真实阅读分钟数（新到旧？——旧到新，index 0 = 29 天前）
    var dailyHistory: [Int]?

    init(
        todayMinutes: Int = 0,
        todayWords: Int = 0,
        currentStreakDays: Int = 0,
        totalMinutesRead: Int = 0,
        totalWordsRead: Int = 0,
        dailyGoalMinutes: Int = 30,
        lastReadDate: Date? = nil,
        weeklyMinutes: [Int] = [0, 0, 0, 0, 0, 0, 0],
        dailyHistory: [Int]? = nil
    ) {
        self.todayMinutes = todayMinutes
        self.todayWords = todayWords
        self.currentStreakDays = currentStreakDays
        self.totalMinutesRead = totalMinutesRead
        self.totalWordsRead = totalWordsRead
        self.dailyGoalMinutes = dailyGoalMinutes
        self.lastReadDate = lastReadDate
        self.weeklyMinutes = weeklyMinutes
        self.dailyHistory = dailyHistory
    }

    var todayProgressRatio: Double {
        guard dailyGoalMinutes > 0 else { return 1.0 }
        return min(1.0, Double(todayMinutes) / Double(dailyGoalMinutes))
    }

    /// 确保历史数组为 30 天（不足补 0，超长截断）
    mutating func ensureHistoryCapacity() {
        if dailyHistory == nil { dailyHistory = [] }
        while dailyHistory!.count < 30 { dailyHistory!.insert(0, at: 0) }
        if dailyHistory!.count > 30 { dailyHistory!.removeFirst(dailyHistory!.count - 30) }
    }

    /// 本周真实总分钟数
    var weekTotalMinutes: Int { weeklyMinutes.reduce(0, +) }

    /// 30 天总分钟数
    var monthTotalMinutes: Int { dailyHistory?.reduce(0, +) ?? 0 }

    /// 日均（30 天口径）
    var monthDailyAverage: Int { monthTotalMinutes / 30 }
}
