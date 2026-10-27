import Foundation
import SwiftUI

@Observable
final class ReadingStatsManager: @unchecked Sendable {
    static let shared = ReadingStatsManager()

    var stats: ReadingStats

    private var activeReadingTimer: Timer?
    private let statsKey = "dreader.reading_stats"

    private init() {
        if let data = UserDefaults.standard.data(forKey: statsKey),
           let decoded = try? JSONDecoder().decode(ReadingStats.self, from: data) {
            self.stats = decoded
        } else {
            self.stats = ReadingStats()
        }
        checkDayRollover()
    }

    func startSession() {
        activeReadingTimer?.invalidate()
        activeReadingTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recordMinuteRead()
            }
        }
    }

    func pauseSession() {
        activeReadingTimer?.invalidate()
        activeReadingTimer = nil
        save()
    }

    func recordMinuteRead() {
        checkDayRollover()
        stats.todayMinutes += 1
        stats.totalMinutesRead += 1
        stats.todayWords += 380
        stats.totalWordsRead += 380

        // Update current weekday
        let weekday = Calendar.current.component(.weekday, from: Date()) - 1
        if stats.weeklyMinutes.indices.contains(weekday) {
            stats.weeklyMinutes[weekday] = max(stats.weeklyMinutes[weekday], stats.todayMinutes)
        }

        // 30 天历史：今天那一格同步累加
        stats.ensureHistoryCapacity()
        if !stats.dailyHistory!.isEmpty {
            stats.dailyHistory![stats.dailyHistory!.count - 1] = stats.todayMinutes
        }
        save()
    }

    private func checkDayRollover() {
        let calendar = Calendar.current
        let today = Date()

        guard let lastDate = stats.lastReadDate else {
            stats.lastReadDate = today
            stats.ensureHistoryCapacity()
            save()
            return
        }

        if !calendar.isDate(lastDate, inSameDayAs: today) {
            // 跨天前先把最后一天的收尾数据写进历史
            if let history = stats.dailyHistory, !history.isEmpty {
                var updated = history
                updated[updated.count - 1] = stats.todayMinutes
                stats.dailyHistory = updated
            }

            // New day! Check if yesterday was read
            if let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
               calendar.isDate(lastDate, inSameDayAs: yesterday) {
                // Maintained streak!
                stats.currentStreakDays += 1
            } else if calendar.isDateInToday(lastDate) {
                // Same day, nothing to roll
            } else {
                // Streak broken or reset
                stats.currentStreakDays = stats.todayMinutes > 0 ? 1 : 0
            }

            stats.todayMinutes = 0
            stats.todayWords = 0
            stats.lastReadDate = today
            stats.ensureHistoryCapacity()
            // 滑动窗口：丢最旧一天，追加今天
            if stats.dailyHistory!.count >= 30 {
                stats.dailyHistory!.removeFirst()
            }
            stats.dailyHistory!.append(0)
            save()
        }
    }

    public func save() {
        if let data = try? JSONEncoder().encode(stats) {
            UserDefaults.standard.set(data, forKey: statsKey)
        }
    }
}
