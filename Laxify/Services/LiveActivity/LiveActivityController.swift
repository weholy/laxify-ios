import ActivityKit
import Foundation
import UIKit

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

    // Written and read only on the main actor (every entry point is
    // main-actor). `nonisolated(unsafe)` just lets the handle be handed to
    // ActivityKit's own async methods without the region checker treating it
    // as escaping the main actor.
    nonisolated(unsafe) private var activity: Activity<NowPlayingActivityAttributes>?
    private var lastPush: Date = .distantPast
    private var lastKey = ""

    /// Tiny JPEG of the current cover, for the card's blurred background.
    private var artworkThumb: Data?
    private var artworkTrackId: String?

    /// Cover for the current track, handed over from the player (which already
    /// downloads the full image for the Lock Screen's system player). Shrunk
    /// hard: it only has to survive a blur, and the whole activity payload is
    /// capped near 4 KB.
    func setArtwork(_ image: UIImage, for trackId: String) {
        artworkTrackId = trackId
        artworkThumb = Self.thumbnail(image)
        pushNow()
    }

    func sync() {
        let player = AudioPlayerController.shared
        guard let song = player.currentSong else { stop(); return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        // New track: drop the old cover until the new one is handed over.
        if artworkTrackId != song.id {
            artworkTrackId = song.id
            artworkThumb = nil
        }

        let state = makeState(song: song, player: player)
        let key = stateKey(state)
        let content = ActivityContent(state: state, staleDate: nil)

        guard activity != nil else {
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

        // A track change, play/pause, or the cover arriving is pushed at once;
        // a plain progress tick, at most every four seconds.
        guard key != lastKey || Date().timeIntervalSince(lastPush) > 4 else { return }
        lastPush = Date()
        lastKey = key
        Task { await activity?.update(content) }
    }

    func stop() {
        artworkThumb = nil
        artworkTrackId = nil
        guard activity != nil else { return }
        lastKey = ""
        Task {
            await activity?.end(nil, dismissalPolicy: .immediate)
            activity = nil
        }
    }

    // MARK: - Private

    /// Push the current state right now, bypassing the throttle — used when
    /// the cover finishes loading so the card doesn't wait for the next tick.
    private func pushNow() {
        let player = AudioPlayerController.shared
        guard activity != nil, let song = player.currentSong else { return }
        let state = makeState(song: song, player: player)
        lastPush = Date()
        lastKey = stateKey(state)
        let content = ActivityContent(state: state, staleDate: nil)
        Task { await activity?.update(content) }
    }

    private func makeState(song: Song, player: AudioPlayerController) -> NowPlayingActivityAttributes.ContentState {
        let progress = player.duration > 0 ? player.currentTime / player.duration : 0
        return NowPlayingActivityAttributes.ContentState(
            title: song.title,
            artist: song.artistName,
            isPlaying: player.isPlaying,
            progress: progress,
            artwork: artworkTrackId == song.id ? artworkThumb : nil
        )
    }

    private func stateKey(_ s: NowPlayingActivityAttributes.ContentState) -> String {
        "\(s.title)|\(s.artist)|\(s.isPlaying)|\(s.artwork?.count ?? 0)"
    }

    /// 64×64 JPEG, dropped entirely if it still wouldn't fit the payload.
    private static func thumbnail(_ image: UIImage) -> Data? {
        let side: CGFloat = 64
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
            .image { _ in image.draw(in: CGRect(x: 0, y: 0, width: side, height: side)) }

        for quality in [0.45, 0.3, 0.2] {
            if let data = rendered.jpegData(compressionQuality: quality), data.count <= 3200 {
                return data
            }
        }
        return nil
    }
}
