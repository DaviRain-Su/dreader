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
        save()
    }

    private func checkDayRollover() {
        let calendar = Calendar.current
        let today = Date()

        guard let lastDate = stats.lastReadDate else {
            stats.lastReadDate = today
            save()
            return
        }

        if !calendar.isDate(lastDate, inSameDayAs: today) {
            // New day! Check if yesterday was read
            if let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
               calendar.isDate(lastDate, inSameDayAs: yesterday) {
                // Maintained streak!
                stats.currentStreakDays += 1
            } else {
                // Streak broken or reset
                stats.currentStreakDays = 1
            }

            stats.todayMinutes = 0
            stats.todayWords = 0
            stats.lastReadDate = today
            save()
        }
    }

    public func save() {
        if let data = try? JSONEncoder().encode(stats) {
            UserDefaults.standard.set(data, forKey: statsKey)
        }
    }
}
