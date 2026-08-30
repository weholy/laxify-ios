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
        /// A tiny JPEG of the cover (~64 px). The whole Live Activity payload
        /// is capped near 4 KB, so this is deliberately small — it only has to
        /// survive a heavy blur as the card's full-bleed background. `nil`
        /// until the cover has downloaded, or if it wouldn't fit.
        var artwork: Data?

        init(
            title: String,
            artist: String,
            isPlaying: Bool,
            progress: Double,
            artwork: Data? = nil
        ) {
            self.title = title
            self.artist = artist
            self.isPlaying = isPlaying
            self.progress = min(max(progress, 0), 1)
            self.artwork = artwork
        }
    }

    /// Nothing dynamic — the activity is always "Laxify playing".
    init() {}
}
