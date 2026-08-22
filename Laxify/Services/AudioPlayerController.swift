import Foundation
import AVFoundation
import MediaPlayer
import UIKit

@MainActor
@Observable
final class AudioPlayerController {
    static let shared = AudioPlayerController()

    private(set) var currentSong: Song?
    private(set) var queue: [Song] = []
    private(set) var currentIndex = 0
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var errorMessage: String?
    private(set) var playbackRate: Double = 1.0
    private(set) var sleepTimerDeadline: Date?

    var hasNext: Bool { currentIndex + 1 < queue.count }
    var hasPrevious: Bool { currentIndex > 0 }

    private var player: AVPlayer?
    private var timeObserverToken: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var didLogFirstTick = false
    private var sleepTimerTask: Task<Void, Never>?
    private var waveBatchId: String?
    private var artworkTrackId: String?
    private var artworkTask: Task<Void, Never>?
    private var reportedStartForTrackId: String?
    private let service: any MusicService

    private init(service: any MusicService = CatalogService.shared) {
        self.service = service
        configureAudioSession()
        configureRemoteCommands()
        AppLogger.log("app: AudioPlayerController initialized")
    }

    private func configureRemoteCommands() {
        CrashReporter.breadcrumb("configuring remote commands")
        let centre = MPRemoteCommandCenter.shared()

        // Every handler is explicitly @Sendable. Without that a closure
        // written inside this main-actor method inherits the actor, and
        // MediaPlayer calling it from a background thread trips Swift
        // Concurrency's queue assertion and kills the process. Each one hops
        // to the main actor itself and answers the system immediately; the
        // status only reports that the request was accepted.
        centre.playCommand.addTarget { @Sendable _ in
            Task { @MainActor in
                let player = AudioPlayerController.shared
                if !player.isPlaying { player.togglePlayPause() }
            }
            return .success
        }

        centre.pauseCommand.addTarget { @Sendable _ in
            Task { @MainActor in
                let player = AudioPlayerController.shared
                if player.isPlaying { player.togglePlayPause() }
            }
            return .success
        }

        centre.togglePlayPauseCommand.addTarget { @Sendable _ in
            Task { @MainActor in
                AudioPlayerController.shared.togglePlayPause()
            }
            return .success
        }

        centre.nextTrackCommand.addTarget { @Sendable _ in
            Task { @MainActor in
                AudioPlayerController.shared.next()
            }
            return .success
        }

        centre.previousTrackCommand.addTarget { @Sendable _ in
            Task { @MainActor in
                AudioPlayerController.shared.previous()
            }
            return .success
        }

        centre.changePlaybackPositionCommand.addTarget { @Sendable event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let position = event.positionTime
            Task { @MainActor in
                AudioPlayerController.shared.seek(to: position)
            }
            return .success
        }

        // Explicitly off rather than left at their defaults, so the Lock
        // Screen shows skip-track arrows instead of seek-by-15s buttons.
        centre.skipForwardCommand.isEnabled = false
        centre.skipBackwardCommand.isEnabled = false
    }

    /// - Parameter waveBatchId: set when the queue came from the personal
    ///   station; playback feedback is only meaningful with a batch to
    ///   attribute it to, and the station learns from that feedback.
    func play(_ song: Song, queue newQueue: [Song] = [], waveBatchId: String? = nil) {
        reportSkipIfNeeded()
        self.waveBatchId = waveBatchId
        queue = newQueue.isEmpty ? [song] : newQueue
        currentIndex = queue.firstIndex(where: { $0.id == song.id }) ?? 0
        loadAndPlayCurrent()
    }

    func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            player.rate = Float(playbackRate)
        }
        isPlaying.toggle()
        updateNowPlayingInfo()
    }

    func next() {
        guard hasNext else { return }
        reportSkipIfNeeded()
        currentIndex += 1
        loadAndPlayCurrent()
    }

    func previous() {
        guard hasPrevious else { return }
        reportSkipIfNeeded()
        currentIndex -= 1
        loadAndPlayCurrent()
    }

    private func reportSkipIfNeeded() {
        reportPlaybackToAccount(completed: false)

        guard waveBatchId != nil, let song = currentSong, currentTime > 0 else { return }
        // Only a genuine skip counts: a track left to finish on its own is
        // reported separately as completed.
        guard currentTime < duration - 5 else { return }
        let trackId = song.id
        let played = currentTime
        Task { await CatalogService.shared.reportWaveTrackSkipped(trackId: trackId, playedSeconds: played) }
    }

    func playIndex(_ index: Int) {
        guard queue.indices.contains(index), index != currentIndex else { return }
        currentIndex = index
        loadAndPlayCurrent()
    }

    func seek(to time: TimeInterval) {
        currentTime = time
        player?.seek(to: CMTime(seconds: time, preferredTimescale: 600))
        updateNowPlayingInfo()
    }

    func setPlaybackRate(_ rate: Double) {
        playbackRate = rate
        if isPlaying {
            player?.rate = Float(rate)
        }
    }

    func setSleepTimer(minutes: Int) {
        sleepTimerTask?.cancel()
        let totalSeconds = minutes * 60
        sleepTimerDeadline = Date().addingTimeInterval(TimeInterval(totalSeconds))
        sleepTimerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(totalSeconds))
            guard !Task.isCancelled else { return }
            self?.pauseForSleepTimer()
        }
    }

    func cancelSleepTimer() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerDeadline = nil
    }

    private func pauseForSleepTimer() {
        player?.pause()
        isPlaying = false
        sleepTimerTask = nil
        sleepTimerDeadline = nil
        updateNowPlayingInfo()
    }

    /// Tracks the source refused within the current queue, so a skip chain
    /// terminates instead of cycling through the same dead entries.
    private var unplayableTrackIds: Set<String> = []

    /// Feeds the current item. Kept alive for as long as it is playing.
    private var streamLoader: StreamLoader?

    /// The playhead, read from the player itself.
    ///
    /// `currentTime` is refreshed by a periodic observer that hops to the
    /// main actor, so by the time a view draws it is already a fraction of a
    /// second stale — enough for lyrics to visibly trail the vocal. Anything
    /// that has to line up with what is being heard should read this instead,
    /// driven by a display-linked timeline rather than by the observer.
    var preciseTime: TimeInterval {
        guard let player else { return currentTime }

        let seconds = player.currentTime().seconds
        guard seconds.isFinite, seconds >= 0 else { return currentTime }
        return seconds
    }

    /// Stops playback and forgets the queue.
    ///
    /// Used when the account changes: leaving the previous person's track
    /// playing, and their queue behind it, is both a surprise and a leak.
    func stopAndClear() {
        teardownPlayer()
        queue = []
        currentIndex = 0
        currentSong = nil
        currentTime = 0
        duration = 0
        isPlaying = false
        isLoading = false
        errorMessage = nil
        waveBatchId = nil
        unplayableTrackIds.removeAll()
        updateNowPlayingInfo()
    }

    private func loadAndPlayCurrent() {
        guard queue.indices.contains(currentIndex) else { return }
        let song = queue[currentIndex]
        AppLogger.log("play: start id=\(song.id) title=\(song.title)")
        CrashReporter.breadcrumb("play start \(song.id)")
        currentSong = song
        currentTime = 0
        duration = song.duration
        isLoading = true
        errorMessage = nil
        teardownPlayer()

        Task {
            var trace = Trace("запуск трека", context: ["track": song.id])

            do {
                // Nothing is fetched before playback starts. A saved copy
                // plays from disk; anything else streams from our own server,
                // whose address is known without asking. Resolving a url first
                // and then having the server resolve it again was most of the
                // wait between a tap and the first sound.
                let item: AVPlayerItem
                if let local = DownloadManager.shared.localURL(for: song.id) {
                    AppLogger.log("play: using downloaded file")
                    item = AVPlayerItem(url: local)
                    streamLoader = nil
                } else {
                    let (streamed, loader) = try await Self.streamingItem(for: song.id)
                    item = streamed
                    // Held so the download can be stopped when the track
                    // changes; a loader with nothing referencing it is
                    // deallocated mid-flight.
                    streamLoader = loader
                }
                trace.mark("ассет создан")

                guard currentSong?.id == song.id else {
                    AppLogger.log("play: song changed while loading, aborting")
                    return
                }
                AppLogger.log("play: created AVPlayerItem")
                let newPlayer = AVPlayer(playerItem: item)
                AppLogger.log("play: created AVPlayer")
                newPlayer.automaticallyWaitsToMinimizeStalling = false
                player = newPlayer
                attachObservers(to: item)
                AppLogger.log("play: observers attached")
                newPlayer.rate = Float(playbackRate)
                AppLogger.log("play: rate set to \(playbackRate)")
                trace.mark("плеер запущен")
                isPlaying = true
                isLoading = false
                updateNowPlayingInfo()
                reportWaveStart(for: song)
                prefetchNext()

                // The moment that actually matters: not when the player was
                // handed an item, but when sound could come out of it.
                Task { [weak self] in
                    await self?.awaitPlayback(of: item, trace: trace)
                }
                AppLogger.log("play: done")
            } catch {
                AppLogger.log("play: ERROR \(error)")
                trace.finish("ошибка")
                RemoteLog.shared.error(
                    "не удалось запустить трек",
                    category: "playback",
                    context: ["track": song.id, "error": "\(error)"]
                )
                isLoading = false
                isPlaying = false

                // Some tracks in the source simply cannot be streamed. Stopping
                // dead on one of those makes a whole queue look broken, so move
                // on instead — the listener wanted music, not this exact track.
                if Self.isUnplayable(error), advancePastUnplayable(song) {
                    return
                }

                if error.isRegionBlocked {
                    errorMessage = "Трек недоступен с этим подключением — проверьте VPN"
                } else {
                    CrashReporter.report("Не удалось воспроизвести трек", detail: "\(error)")
                    errorMessage = "Не удалось воспроизвести трек"
                }
            }
        }
    }

    /// True when the source cannot produce a stream for this track at all,
    /// as opposed to the network being down.
    private static func isUnplayable(_ error: Error) -> Bool {
        guard case MusicServiceError.underlying(let underlying) = error,
              case APIError.server(let status, _) = underlying else {
            return false
        }
        return status == 502 || status == 404
    }

    /// Skips to the next track that has not already failed.
    ///
    /// Returns false once the whole queue has been tried, so the caller can
    /// show a message rather than loop.
    private func advancePastUnplayable(_ song: Song) -> Bool {
        unplayableTrackIds.insert(song.id)

        guard let next = queue.indices.first(where: { index in
            index > currentIndex && !unplayableTrackIds.contains(queue[index].id)
        }) else {
            unplayableTrackIds.removeAll()
            return false
        }

        AppLogger.log("play: skipping unplayable \(song.id)")
        currentIndex = next
        loadAndPlayCurrent()
        return true
    }

    /// An item that streams through our own server, fetched in one go.
    ///
    /// The signed url the source hands out is bound to the region it was
    /// issued in, so a phone elsewhere is refused even though the link looks
    /// valid. The server holds the matching signature and passes the bytes
    /// on.
    ///
    /// Those bytes arrive as a single download rather than as the six or
    /// eight ranged requests AVPlayer would make on its own — on a slow link
    /// those round trips were the whole wait before playback began.
    private static func streamingItem(for trackId: String) async throws -> (AVPlayerItem, StreamLoader) {
        guard let proxy = await LaxifyAPI.shared.proxyAudioRequest(trackId: trackId) else {
            throw MusicServiceError.missingAccessKey
        }

        let loader = StreamLoader(
            source: proxy.url,
            headers: proxy.headers,
            usesPinnedTrust: await LaxifyAPI.shared.routeNeedsPinnedTrust
        )

        let item = AVPlayerItem(asset: loader.makeAsset())
        // Everything is local by the time the player asks, so there is
        // nothing to gain from buffering ahead.
        item.preferredForwardBufferDuration = 1
        return (item, loader)
    }

    /// Warms the next track on the server while this one plays.
    ///
    /// Resolving a stream costs the server two calls upstream; doing it
    /// before the listener asks makes the next track start immediately.
    private func prefetchNext() {
        guard queue.indices.contains(currentIndex + 1) else { return }
        let nextId = queue[currentIndex + 1].id
        guard DownloadManager.shared.localURL(for: nextId) == nil else { return }

        Task.detached(priority: .background) {
            await LaxifyAPI.shared.warmStream(trackId: nextId)
        }
    }

    /// Waits for the item to be playable, and reports how long that took.
    ///
    /// Everything up to this point is bookkeeping; this is the part a
    /// listener experiences as the wait.
    private func awaitPlayback(of item: AVPlayerItem, trace: Trace) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))

        while ContinuousClock.now < deadline {
            if item.status == .failed {
                trace.finish("ассет не открылся")
                RemoteLog.shared.error(
                    "ассет не открылся",
                    category: "playback",
                    context: ["error": item.error.map { "\($0)" } ?? "неизвестно"]
                )
                return
            }

            if item.status == .readyToPlay, item.isPlaybackLikelyToKeepUp {
                trace.finish("звук пошёл")
                return
            }

            try? await Task.sleep(for: .milliseconds(50))
        }

        trace.finish("не дождались")
        RemoteLog.shared.warn("трек не начал играть за 30 с", category: "playback")
    }

    private func attachObservers(to item: AVPlayerItem) {
        didLogFirstTick = false

        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserverToken = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                if !self.didLogFirstTick {
                    AppLogger.log("play: first periodic tick t=\(time.seconds)")
                    self.didLogFirstTick = true
                }
                let delta = time.seconds - self.currentTime
                if delta > 0, delta < 2 {
                    ListeningStatsService.shared.recordPlayback(seconds: delta)
                }
                self.currentTime = time.seconds
            }
        }

        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                AppLogger.log("play: did play to end time")
                self?.handleDidFinishPlaying()
            }
        }

        statusObservation = item.observe(\.status, options: [.new]) { observedItem, _ in
            Task { @MainActor in
                switch observedItem.status {
                case .readyToPlay:
                    AppLogger.log("play: item status = readyToPlay")
                case .failed:
                    let description = observedItem.error?.localizedDescription ?? "unknown"
                    AppLogger.log("play: item status = FAILED \(description)")
                case .unknown:
                    AppLogger.log("play: item status = unknown")
                @unknown default:
                    AppLogger.log("play: item status = other")
                }
            }
        }
    }

    private func handleDidFinishPlaying() {
        reportPlaybackToAccount(completed: true)
        reportWaveFinished()

        if hasNext {
            // Deliberately not via next(): that would log a skip for a track
            // the listener actually played all the way through.
            currentIndex += 1
            loadAndPlayCurrent()
        } else {
            isPlaying = false
            updateNowPlayingInfo()
        }
    }

    private func reportWaveStart(for song: Song) {
        guard let batchId = waveBatchId, reportedStartForTrackId != song.id else { return }
        reportedStartForTrackId = song.id
        let trackId = song.id
        Task { await CatalogService.shared.reportWaveTrackStarted(trackId: trackId, batchId: batchId) }
    }

    /// Reports the finished track to the account so stats and
    /// recommendations reflect every device, not just this one.
    private func reportPlaybackToAccount(completed: Bool) {
        guard let song = currentSong, currentTime > 3 else { return }
        SyncService.shared.recordPlayback(
            song: song,
            seconds: currentTime,
            completed: completed,
            source: waveBatchId == nil ? "library" : "wave"
        )
    }

    private func reportWaveFinished() {
        guard let batchId = waveBatchId, let song = currentSong else { return }
        let trackId = song.id
        let played = max(currentTime, duration)
        Task {
            await CatalogService.shared.reportWaveTrackFinished(
                trackId: trackId, batchId: batchId, playedSeconds: played
            )
        }
    }

    private func teardownPlayer() {
        streamLoader?.cancel()
        streamLoader = nil

        if let timeObserverToken {
            player?.removeTimeObserver(timeObserverToken)
        }
        timeObserverToken = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil
        player?.pause()
        player = nil
    }

    private func configureAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func updateNowPlayingInfo() {
        guard let song = currentSong else { return }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.artistName,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? playbackRate : 0
        ]
        if let albumTitle = song.albumTitle {
            info[MPMediaItemPropertyAlbumTitle] = albumTitle
        }
        // Keep any artwork already attached for this track so a metadata
        // refresh (play/pause, seek) does not blank the cover for a moment.
        if let existing = MPNowPlayingInfoCenter.default().nowPlayingInfo?[
            MPMediaItemPropertyArtwork
        ] as? MPMediaItemArtwork, artworkTrackId == song.id {
            info[MPMediaItemPropertyArtwork] = existing
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        loadArtworkIfNeeded(for: song)
    }

    /// Downloads the cover once per track and hands it to the system.
    private func loadArtworkIfNeeded(for song: Song) {
        guard artworkTrackId != song.id, let url = song.coverURL else { return }
        artworkTrackId = song.id
        CrashReporter.breadcrumb("artwork load \(song.id)")

        artworkTask?.cancel()
        // Detached on purpose. A Task started from this main-actor class
        // inherits its isolation, and that isolation is inherited by the
        // artwork request handler created inside it — MediaPlayer then calls
        // that handler from a background thread, Swift Concurrency asserts it
        // is on the main queue, and the process dies with SIGTRAP. Detaching,
        // plus the explicit @Sendable handler below, keeps the handler free of
        // any actor so the system may call it from wherever it likes.
        artworkTask = Task.detached(priority: .utility) {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data),
                  !Task.isCancelled else {
                return
            }

            let handler: @Sendable (CGSize) -> UIImage = { _ in image }
            let artwork = MPMediaItemArtwork(boundsSize: image.size, requestHandler: handler)

            await MainActor.run {
                let player = AudioPlayerController.shared
                guard player.currentSong?.id == song.id else { return }

                var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                info[MPMediaItemPropertyArtwork] = artwork
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            }
        }
    }
}
