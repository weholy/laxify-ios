import ActivityKit
import Foundation

/// Shape of the "now playing" Live Activity — the presence in the Dynamic
/// Island and on the Lock Screen while Laxify is playing.
///
/// Compiled into both the app (which starts and updates the activity) and the
/// widget extension (which draws it), so it lives in `Shared/`.
struct NowPlayingActivityAttributes: ActivityAttributes, Sendable {
    struct ContentState: Codable, Hashable, Sendable {
        var title: String
        var artist: String
        var isPlaying: Bool
        /// 0…1, for the thin progress line. A plain number rather than a live
        /// `ProgressView(timerInterval:)` so a pause freezes it.
        var progress: Double

        init(title: String, artist: String, isPlaying: Bool, progress: Double) {
            self.title = title
            self.artist = artist
            self.isPlaying = isPlaying
            self.progress = min(max(progress, 0), 1)
        }
    }

    /// Nothing dynamic — the activity is always "Laxify playing".
    init() {}
}
