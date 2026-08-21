import Foundation

@MainActor
@Observable
final class ListeningStatsService {
    static let shared = ListeningStatsService()

    private(set) var totalSecondsListened: TimeInterval

    private let defaults = UserDefaults.standard
    private let totalSecondsKey = "laxify.stats.totalSeconds"

    private init() {
        totalSecondsListened = defaults.double(forKey: totalSecondsKey)
    }

    func recordPlayback(seconds: TimeInterval) {
        guard seconds > 0 else { return }
        totalSecondsListened += seconds
        defaults.set(totalSecondsListened, forKey: totalSecondsKey)
    }
}
