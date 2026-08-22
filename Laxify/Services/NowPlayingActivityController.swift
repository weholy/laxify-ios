import ActivityKit
import Foundation

/// Drives the Dynamic Island / Lock Screen Live Activity.
///
/// Updates are throttled: the playback clock ticks ten times a second, but the
/// system rate-limits activity updates and will start dropping them (and
/// burning battery) if pushed at that rate. Once a second is enough for a
/// progress bar, with immediate updates when the track or play state changes.
@MainActor
final class NowPlayingActivityController {
    static let shared = NowPlayingActivityController()

    private var activity: Activity<NowPlayingAttributes>?
    private var lastPushedAt: Date = .distantPast
    private var lastTrackId: String?

    private let minimumInterval: TimeInterval = 1.0

    private init() {}

    var isSupported: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// Called on every player change; decides whether the activity needs to
    /// start, update or end.
    func refresh() {
        let player = AudioPlayerController.shared

        guard let song = player.currentSong else {
            end()
            return
        }

        let state = NowPlayingAttributes.ContentState(
            title: song.title,
            artist: song.artistName,
            isPlaying: player.isPlaying,
            isFavorite: FavoriteToggler.shared.isCurrentFavorite,
            progress: player.duration > 0 ? player.currentTime / player.duration : 0,
            elapsed: player.currentTime,
            duration: player.duration,
            coverURLString: song.coverURL?.absoluteString
        )

        let trackChanged = song.id != lastTrackId

        if activity == nil {
            start(with: state, trackId: song.id)
            return
        }

        // Track and play-state changes are worth an immediate update; plain
        // progress can wait for the next slot.
        let dueForUpdate = Date().timeIntervalSince(lastPushedAt) >= minimumInterval
        guard trackChanged || dueForUpdate else { return }

        lastTrackId = song.id
        lastPushedAt = Date()

        Task {
            await activity?.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    private func start(with state: NowPlayingAttributes.ContentState, trackId: String) {
        guard isSupported else { return }

        do {
            activity = try Activity.request(
                attributes: NowPlayingAttributes(sessionName: "Laxify"),
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
            lastTrackId = trackId
            lastPushedAt = Date()
        } catch {
            AppLogger.log("live activity: failed to start — \(error)")
        }
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        lastTrackId = nil

        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
