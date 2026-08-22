import ActivityKit
import Foundation

/// Shared between the app and the widget extension.
///
/// Only the fields the Live Activity actually draws live here — anything
/// bigger would be copied into the activity payload on every update, and the
/// system caps how much state an activity may carry.
struct NowPlayingAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var artist: String
        var isPlaying: Bool
        var isFavorite: Bool
        var progress: Double
        var elapsed: TimeInterval
        var duration: TimeInterval
        var coverURLString: String?

        var coverURL: URL? {
            coverURLString.flatMap(URL.init(string:))
        }
    }

    /// Constant for the life of the activity; the track itself lives in
    /// ContentState because it changes as the queue advances.
    var sessionName: String
}
