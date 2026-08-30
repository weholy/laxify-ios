import ActivityKit
import Foundation

/// Keeps the "now playing" Live Activity — the Dynamic Island / Lock Screen
/// presence — in step with the player.
///
/// `sync()` is called from `updateNowPlayingInfo()`, so it fires on every
/// track change, play/pause and roughly every 1.5s while playing. It is
/// cheap: a bare progress tick is pushed at most every few seconds, and a
/// no-op when nothing moved.
@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()
    private init() {}

    private var activity: Activity<NowPlayingActivityAttributes>?
    private var lastPush: Date = .distantPast
    private var lastKey = ""

    func sync() {
        let player = AudioPlayerController.shared
        guard let song = player.currentSong else { stop(); return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let progress = player.duration > 0 ? player.currentTime / player.duration : 0
        let state = NowPlayingActivityAttributes.ContentState(
            title: song.title,
            artist: song.artistName,
            isPlaying: player.isPlaying,
            progress: progress
        )
        let key = "\(state.title)|\(state.artist)|\(state.isPlaying)"

        guard let activity else {
            let content = ActivityContent(state: state, staleDate: nil)
            do {
                activity = try Activity.request(
                    attributes: NowPlayingActivityAttributes(),
                    content: content
                )
                lastPush = Date()
                lastKey = key
            } catch {
                AppLogger.log("liveactivity: request failed \(error)")
            }
            return
        }

        // A track change or a play/pause is pushed at once; a plain progress
        // tick, at most every four seconds.
        guard key != lastKey || Date().timeIntervalSince(lastPush) > 4 else { return }
        lastPush = Date()
        lastKey = key

        let content = ActivityContent(state: state, staleDate: nil)
        Task { [activity] in await activity.update(content) }
    }

    func stop() {
        guard let activity else { return }
        self.activity = nil
        lastKey = ""
        Task { [activity] in await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
