import Foundation
import AVFoundation
import SwiftData
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

    /// Whether the queue currently playing is the personal wave. Its defining
    /// property is that it never ends — the tail is refilled as it is neared.
    var isPlayingWave: Bool { waveBatchId != nil && currentSong != nil }

    private var isExtendingWave = false

    private var player: AVPlayer?
    private var timeObserverToken: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var durationObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var didLogFirstTick = false
    /// Control Center extrapolates the scrubber from the last published
    /// elapsed time + rate; if it is only pushed on play/pause/seek it drifts
    /// (stalls, buffering) and the bar sticks. Re-push on a short interval.
    private var lastNowPlayingPush: Date = .distantPast
    private var sleepTimerTask: Task<Void, Never>?

    // Crossfade: a second player fades in over the tail of the current one.
    private var crossfadePlayer: AVPlayer?
    private var crossfadeTask: Task<Void, Never>?
    private var isCrossfading = false
    /// So the tail-of-track check only fires the fade once per song.
    private var crossfadeArmedForTrackId: String?
    /// Fires once when the playhead reaches `duration - window`. Unlike the
    /// periodic observer this is honoured during background audio, so the
    /// fade still starts with the screen locked.
    private var crossfadeBoundaryObserver: Any?

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
            crossfadePlayer?.pause()
        } else {
            player.rate = Float(playbackRate)
            crossfadePlayer?.play()
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
        // Scrubbing back into the track cancels a fade that had already begun,
        // and makes the track eligible to fade again from its new position.
        let wasCrossfading = isCrossfading
        if wasCrossfading { cancelCrossfade() }
        currentTime = time
        player?.seek(to: CMTime(seconds: time, preferredTimescale: 600))
        if wasCrossfading { armCrossfadeBoundary() }
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
    /// What happens when the queue reaches its end.
    enum RepeatMode: String, CaseIterable {
        /// Play through and stop.
        case off
        /// Start the queue again from the top.
        case all
        /// Play the current track over and over.
        case one

        var next: RepeatMode {
            switch self {
            case .off: .all
            case .all: .one
            case .one: .off
            }
        }
    }

    /// Persisted, because it is a preference rather than a property of one
    /// listening session.
    var repeatMode: RepeatMode = RepeatMode(
        rawValue: UserDefaults.standard.string(forKey: "laxify.player.repeat") ?? ""
    ) ?? .all {
        didSet { UserDefaults.standard.set(repeatMode.rawValue, forKey: "laxify.player.repeat") }
    }

    func cycleRepeatMode() {
        repeatMode = repeatMode.next
    }

    enum CrossfadeDuration: Int, CaseIterable, Identifiable, Sendable {
        case off = 0, s4 = 4, s6 = 6, s9 = 9, s12 = 12
        var id: Int { rawValue }
        var seconds: Double { Double(rawValue) }
    }

    var crossfadeDuration: CrossfadeDuration =
        CrossfadeDuration(rawValue: UserDefaults.standard.integer(forKey: "laxify.player.crossfade")) ?? .off
    {
        didSet { UserDefaults.standard.set(crossfadeDuration.rawValue, forKey: "laxify.player.crossfade") }
    }

    private var unplayableTrackIds: Set<String> = []

    /// Feeds the current item. Kept alive for as long as it is playing.
    private var streamLoader: StreamLoader?

    /// Set by the root view, so plays can be written to the device's own
    /// record as well as sent to the account.
    var modelContext: ModelContext?

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
        cancelCrossfade()
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
        LiveActivityController.shared.stop()
        updateNowPlayingInfo()
    }

    private func loadAndPlayCurrent() {
        guard queue.indices.contains(currentIndex) else { return }
        cancelCrossfade()
        let song = queue[currentIndex]
        AppLogger.log("play: start id=\(song.id) title=\(song.title)")
        CrashReporter.breadcrumb("play start \(song.id)")
        currentSong = song
        extendWaveQueueIfNeeded()
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
                // Left on: the player knows better than a fixed rule when
                // it has enough to keep going, and turning it off is what
                // produced stalls a few seconds in.
                newPlayer.automaticallyWaitsToMinimizeStalling = true
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

    /// An item to play.
    ///
    /// The url is resolved by this device, so the signature it carries was
    /// issued for this device — the reason a link obtained by our server was
    /// refused here. It points straight at the media host, which answers in
    /// about a tenth of a second.
    ///
    /// Handed to the player as an ordinary url, with no loader of ours in
    /// between. There was one, from when audio came through our server and
    /// each of the player's ranged requests cost a slow round trip; feeding
    /// the player ourselves meant telling it how long the track was, and
    /// getting that slightly wrong made it stop a third of the way through
    /// and move on. The media host answers ranges correctly and quickly, so
    /// the player is better left to do this itself.
    private static func streamingItem(for trackId: String) async throws -> (AVPlayerItem, StreamLoader?) {
        if let direct = try? await SoundCloudDirect.shared.streamURL(for: trackId) {
            let asset = AVURLAsset(
                url: direct,
                // Lets the player start on what has arrived instead of
                // waiting for a comfortable buffer.
                options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
            )
            return (AVPlayerItem(asset: asset), nil)
        }

        // Only when the source cannot be reached directly. Slower, and the
        // signature may not be valid here, but better than silence — and the
        // loader earns its place on this path, where every ranged request
        // would otherwise be a round trip to a server that barely answers.
        guard let proxy = await LaxifyAPI.shared.proxyAudioRequest(trackId: trackId) else {
            throw MusicServiceError.notFound
        }

        let loader = StreamLoader(
            source: proxy.url,
            headers: proxy.headers,
            usesPinnedTrust: await LaxifyAPI.shared.routeNeedsPinnedTrust
        )

        return (AVPlayerItem(asset: loader.makeAsset()), loader)
    }

    /// Resolves the next track's url while this one plays.
    ///
    /// Resolving costs two requests to the source, and doing them before the
    /// listener asks means the next track starts on the first tap.
    private func prefetchNext() {
        guard queue.indices.contains(currentIndex + 1) else { return }
        let nextId = queue[currentIndex + 1].id
        guard DownloadManager.shared.localURL(for: nextId) == nil else { return }

        Task.detached(priority: .background) {
            _ = try? await SoundCloudDirect.shared.streamURL(for: nextId)
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
                self.maybeStartCrossfade()

                // Keep the lock-screen / Control Center scrubber honest — it
                // otherwise runs on its own clock between the sparse
                // play/pause/seek pushes and visibly lags after a stall or a
                // track change.
                if Date().timeIntervalSince(self.lastNowPlayingPush) > 1.5 {
                    self.updateNowPlayingInfo()
                }
            }
        }

        // A stall or an automatic wait must show as rate 0 immediately, and a
        // resume as rate 1 — otherwise the system card keeps advancing the bar
        // through silence.
        timeControlObservation = player?.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.updateNowPlayingInfo() }
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

        // The real asset duration, once the player knows it. Metadata from
        // the source is an estimate — for some tracks wrong by enough that a
        // bar bound to it reaches the end early or never gets there. It
        // arrives late (and sometimes as `indefinite`), so an observer rather
        // than a one-time read.
        durationObservation = item.observe(\.duration, options: [.new, .initial]) { [weak self] observedItem, _ in
            let seconds = observedItem.duration.seconds
            Task { @MainActor in
                guard let self, self.currentSong != nil else { return }
                guard seconds.isFinite, seconds > 1, abs(self.duration - seconds) > 1 else { return }
                self.duration = seconds
                // The fade is scheduled off the real duration, so re-place it
                // now that it is known rather than off the metadata estimate.
                self.armCrossfadeBoundary()
                self.updateNowPlayingInfo()
            }
        }

        armCrossfadeBoundary()
    }

    // MARK: - Crossfade

    private func cancelCrossfade() {
        crossfadeTask?.cancel()
        crossfadeTask = nil
        crossfadePlayer?.pause()
        crossfadePlayer = nil
        isCrossfading = false
        crossfadeArmedForTrackId = nil
        player?.volume = 1
        disarmCrossfadeBoundary()
    }

    private func disarmCrossfadeBoundary() {
        if let crossfadeBoundaryObserver {
            player?.removeTimeObserver(crossfadeBoundaryObserver)
        }
        crossfadeBoundaryObserver = nil
    }

    /// Schedules the fade to begin when the playhead reaches `duration -
    /// window`. Re-armed whenever the real duration is learned (the metadata
    /// estimate it starts from can be off by several seconds).
    private func armCrossfadeBoundary() {
        disarmCrossfadeBoundary()

        let window = crossfadeDuration.seconds
        guard window > 0, let player,
              duration.isFinite, duration > window + 3
        else { return }

        let fireAt = CMTime(seconds: duration - window, preferredTimescale: 600)
        crossfadeBoundaryObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: fireAt)], queue: .main
        ) { [weak self] in
            Task { @MainActor in self?.maybeStartCrossfade() }
        }
    }

    /// Starts the fade if the current track is within the window of its end.
    /// Driven both by the boundary observer above and, as a fallback, by the
    /// periodic time observer.
    private func maybeStartCrossfade() {
        let window = crossfadeDuration.seconds
        guard window > 0,
              !isCrossfading,
              isPlaying,
              repeatMode != .one,
              hasNext,
              duration > window + 2,
              currentTime >= duration - window - 0.5,
              currentTime < duration - 0.5,
              crossfadeArmedForTrackId != currentSong?.id
        else { return }

        crossfadeArmedForTrackId = currentSong?.id
        isCrossfading = true
        let nextSong = queue[currentIndex + 1]
        // Never ramp for longer than there is audio left on the outgoing side,
        // or the current track ends mid-fade into silence.
        let remaining = max(1.0, duration - currentTime - 0.25)
        let ramp = min(window, remaining)

        crossfadeTask = Task { [weak self] in
            guard let self else { return }
            guard let (item, loader) = try? await Self.streamingItem(for: nextSong.id) else {
                self.abortCrossfade()
                return
            }
            await self.runCrossfade(to: nextSong, item: item, loader: loader, over: ramp)
        }
    }

    /// Give up on the fade and let the ordinary end-of-track handler do a
    /// clean cut instead.
    private func abortCrossfade() {
        crossfadePlayer?.pause()
        crossfadePlayer = nil
        isCrossfading = false
        crossfadeArmedForTrackId = nil
        player?.volume = 1
    }

    private func runCrossfade(
        to song: Song, item: AVPlayerItem, loader: StreamLoader?, over ramp: Double
    ) async {
        let outgoing = player
        let incoming = AVPlayer(playerItem: item)
        incoming.volume = 0
        incoming.automaticallyWaitsToMinimizeStalling = true
        crossfadePlayer = incoming

        // Wait until the incoming track can actually produce sound. Ramping
        // before it is ready fades the current track down into a gap and then
        // slams the next one in at full volume — which is what "crossfade
        // doesn't work" looked like.
        let ready = await Self.waitUntilReady(item, timeout: 3.0)
        guard !Task.isCancelled else { incoming.pause(); return }
        guard ready else {
            abortCrossfade()
            return
        }

        incoming.play()
        incoming.rate = Float(playbackRate)

        let steps = max(Int(ramp / 0.05), 1)
        for step in 0...steps {
            if Task.isCancelled { incoming.pause(); return }
            // Honour a pause during the fade: hold the ramp where it is.
            while !isPlaying && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if Task.isCancelled { incoming.pause(); return }
            let t = Float(step) / Float(steps)
            outgoing?.volume = 1 - t
            incoming.volume = t
            try? await Task.sleep(for: .milliseconds(50))
        }
        if Task.isCancelled { incoming.pause(); return }

        // The old track played to its natural end — count it, don't skip-log it.
        reportPlaybackToAccount(completed: true)
        reportWaveFinished()

        teardownPlayer()          // stops + releases the outgoing player and its observers
        player = incoming
        crossfadePlayer = nil
        streamLoader = loader
        incoming.volume = 1

        currentIndex += 1
        currentSong = song
        currentTime = 0
        duration = song.duration
        isPlaying = true
        isLoading = false
        crossfadeArmedForTrackId = nil
        isCrossfading = false

        attachObservers(to: item)
        armCrossfadeBoundary()
        extendWaveQueueIfNeeded()
        reportWaveStart(for: song)
        prefetchNext()
        updateNowPlayingInfo()
        loadArtworkIfNeeded(for: song)
    }

    /// Polls an item to `.readyToPlay`, up to `timeout` seconds.
    private static func waitUntilReady(_ item: AVPlayerItem, timeout: Double) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while ContinuousClock.now < deadline {
            if item.status == .readyToPlay { return true }
            if item.status == .failed { return false }
            try? await Task.sleep(for: .milliseconds(40))
        }
        return item.status == .readyToPlay
    }

    private func handleDidFinishPlaying() {
        // A crossfade already advanced the queue; the end-of-item on the old
        // player is nothing to act on.
        if isCrossfading { return }

        reportPlaybackToAccount(completed: true)
        reportWaveFinished()

        if repeatMode == .one {
            // Same track again, from the top. Reported as finished first, so
            // a track on repeat counts every time it plays.
            seek(to: 0)
            player?.play()
            isPlaying = true
            updateNowPlayingInfo()
            return
        }

        if hasNext {
            // Deliberately not via next(): that would log a skip for a track
            // the listener actually played all the way through.
            currentIndex += 1
            loadAndPlayCurrent()
            return
        }

        // A wave never ends. If the buffer emptied faster than it refilled,
        // wait for one more run rather than stopping the music.
        if waveBatchId != nil {
            Task {
                await extendWaveQueue()
                if hasNext {
                    currentIndex += 1
                    loadAndPlayCurrent()
                } else {
                    isPlaying = false
                    updateNowPlayingInfo()
                }
            }
            return
        }

        if repeatMode == .all, !queue.isEmpty {
            currentIndex = 0
            loadAndPlayCurrent()
            return
        }

        isPlaying = false
        updateNowPlayingInfo()
    }

    // MARK: - Wave continuation

    /// Pulls the next wave run and appends what is new. One fetch at a time,
    /// and only ever near the tail — the personal radio the source runs is
    /// endless, so the queue has to be too, no matter which screen started it.
    private func extendWaveQueue() async {
        guard waveBatchId != nil, !isExtendingWave, let lastId = queue.last?.id else { return }
        isExtendingWave = true
        defer { isExtendingWave = false }

        guard let batch = try? await CatalogService.shared.waveBatch(lastTrackId: lastId),
              waveBatchId != nil else { return }

        let existing = Set(queue.map(\.id))
        // Spread artists out: three tracks by the same person in a row is the
        // one thing that most makes a "wave" feel like a shuffle of a library.
        var recentArtists = Set(queue.suffix(8).compactMap { $0.artistId }.filter { !$0.isEmpty })

        var fresh: [Song] = []
        for song in batch.songs where !existing.contains(song.id) {
            let artist = song.artistId ?? ""
            if !artist.isEmpty, recentArtists.contains(artist) { continue }
            if !artist.isEmpty { recentArtists.insert(artist) }
            fresh.append(song)
        }

        // The spread filter left nothing — a thin batch, or one artist's
        // playlist. Better a repeat than silence.
        if fresh.isEmpty {
            fresh = batch.songs.filter { !existing.contains($0.id) }
        }
        guard !fresh.isEmpty else { return }

        // Keep the original batch id: one wave session, one id. The new
        // batch's own id is client-generated and only ever nil-checked.
        queue.append(contentsOf: fresh)
    }

    private func extendWaveQueueIfNeeded() {
        guard waveBatchId != nil, !isExtendingWave, currentIndex >= queue.count - 3 else { return }
        Task { await extendWaveQueue() }
    }

    /// Drops the unplayed tail and refills it from the wave, so what comes
    /// next reflects a signal that just changed — a settings tweak, usually.
    func reshapeWaveTail() {
        guard waveBatchId != nil else { return }
        Task {
            if currentIndex < queue.count - 1 {
                queue.removeSubrange((currentIndex + 1)...)
            }
            await extendWaveQueue()
        }
    }

    /// Skips the current track, then reshapes what follows once the dislike
    /// that prompted it has actually reached the server.
    func skipAndReshapeWave() {
        let couldAdvance = hasNext
        if couldAdvance { next() }
        guard waveBatchId != nil else { return }

        Task {
            await SyncOutbox.shared.flush()
            if currentIndex < queue.count - 1 {
                queue.removeSubrange((currentIndex + 1)...)
            }
            await extendWaveQueue()
            if !couldAdvance, hasNext {
                currentIndex += 1
                loadAndPlayCurrent()
            }
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

        // Written to disk first, and only marked as sent once the server has
        // it. Plays used to wait twenty seconds in memory before being
        // persisted anywhere, so closing the app inside that window lost
        // them — and the queue they joined gave up after eight failures,
        // which with an unreachable server discarded whole evenings.
        LocalReplay.record(song, seconds: currentTime, completed: completed, context: modelContext)

        let context = modelContext
        Task { await PlaybackUploader.flush(context: context) }
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
        if let crossfadeBoundaryObserver {
            player?.removeTimeObserver(crossfadeBoundaryObserver)
        }
        crossfadeBoundaryObserver = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil
        durationObservation?.invalidate()
        durationObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        player?.pause()
        player = nil
    }

    private func configureAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func updateNowPlayingInfo() {
        guard let song = currentSong else { return }

        lastNowPlayingPush = Date()

        // Never hand the system a nonsense duration — a zero or an infinity
        // makes the scrubber jump to an end it never reaches.
        let safeDuration = (duration.isFinite && duration > 0) ? duration : max(currentTime, 1)
        let safeElapsed = min(max(currentTime, 0), safeDuration)
        // Rate 0 whenever the player is not actually producing sound, so the
        // bar stops instead of drifting on through a stall.
        let liveRate = (isPlaying && player?.timeControlStatus == .playing) ? playbackRate : 0

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.artistName,
            MPMediaItemPropertyPlaybackDuration: safeDuration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: safeElapsed,
            MPNowPlayingInfoPropertyPlaybackRate: liveRate
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
        LiveActivityController.shared.sync()
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
