import Foundation

@MainActor
@Observable
final class ListeningStatsService {
    static let shared = ListeningStatsService()

    private(set) var totalSecondsListened: TimeInterval
    private(set) var currentStreak: Int
    private(set) var longestStreak: Int

    private let defaults = UserDefaults.standard
    private let totalSecondsKey = "laxify.stats.totalSeconds"
    private let currentStreakKey = "laxify.stats.currentStreak"
    private let longestStreakKey = "laxify.stats.longestStreak"
    private let lastListenedDayKey = "laxify.stats.lastListenedDay"

    private init() {
        totalSecondsListened = defaults.double(forKey: totalSecondsKey)
        currentStreak = defaults.integer(forKey: currentStreakKey)
        longestStreak = defaults.integer(forKey: longestStreakKey)
    }

    func recordPlayback(seconds: TimeInterval) {
        guard seconds > 0 else { return }
        totalSecondsListened += seconds
        defaults.set(totalSecondsListened, forKey: totalSecondsKey)
        updateStreakIfNeeded()
    }

    private func updateStreakIfNeeded() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)

        guard let lastDay = defaults.object(forKey: lastListenedDayKey) as? Date else {
            currentStreak = 1
            longestStreak = max(longestStreak, currentStreak)
            persistStreak(lastDay: today)
            return
        }

        let lastDayStart = calendar.startOfDay(for: lastDay)
        guard lastDayStart != today else { return }

        let daysBetween = calendar.dateComponents([.day], from: lastDayStart, to: today).day ?? 0
        currentStreak = daysBetween == 1 ? currentStreak + 1 : 1
        longestStreak = max(longestStreak, currentStreak)
        persistStreak(lastDay: today)
    }

    private func persistStreak(lastDay: Date) {
        defaults.set(currentStreak, forKey: currentStreakKey)
        defaults.set(longestStreak, forKey: longestStreakKey)
        defaults.set(lastDay, forKey: lastListenedDayKey)
    }
}
