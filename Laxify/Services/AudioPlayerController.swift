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
        let wasWave = waveBatchId != nil
        reportSkipIfNeeded()
        currentIndex += 1
        loadAndPlayCurrent()
        // A skip in the wave should change what comes next, not just move to
        // the track that was already queued — the way Yandex's does. Reshape
        // the tail once the skip has reached the server.
        if wasWave { Task { await reshapeWaveTailAfterSkip() } }
    }

    func previous() {
        guard hasPrevious else { return }
        reportSkipIfNeeded()
        currentIndex -= 1
        loadAndPlayCurrent()
    }

    /// The in-flight "track skipped" report, so a reshape can wait for it to
    /// land before asking the server for the next batch.
    private var pendingSkipReport: Task<Void, Never>?

    private func reportSkipIfNeeded() {
        reportPlaybackToAccount(completed: false)

        guard let batchId = waveBatchId, let song = currentSong, currentTime > 0 else { return }
        // Only a genuine skip counts: a track left to finish on its own is
        // reported separately as completed.
        guard currentTime < duration - 5 else { return }
        let trackId = song.id
        let played = currentTime
        pendingSkipReport = Task {
            await CatalogService.shared.reportWaveTrackSkipped(
                trackId: trackId, batchId: batchId, playedSeconds: played
            )
        }
    }

    private func reshapeWaveTailAfterSkip() async {
        guard let sessionId = waveBatchId else { return }
        await pendingSkipReport?.value
        guard waveBatchId == sessionId, !isExtendingWave else { return }
        if currentIndex < queue.count - 1 {
            queue.removeSubrange((currentIndex + 1)...)
        }
        await extendWaveQueue()
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

        // Remembered until the player actually arrives. A seek is asynchronous
        // and `currentTime()` reports the old position the whole time it is in
        // flight — long enough on a streaming asset to see the lyrics keep
        // highlighting the line you scrubbed away from, and then jump.
        //
        // The deadline is the half of this that matters. AVPlayer does not
        // guarantee its completion handler runs if the player itself is
        // deallocated first — and `teardownPlayer` does exactly that the
        // moment a scrub is followed by a track change, which is an ordinary
        // thing to do. Without the deadline a dropped completion left this
        // stuck at one scrubbed position for the rest of the session: every
        // lyric on every track after it would read against a frozen number,
        // which is exactly what "text stopped keeping up" was.
        pendingSeek = PendingSeek(target: time, expiresAt: .now + .seconds(2))

        player?.seek(to: CMTime(seconds: time, preferredTimescale: 600)) { [weak self] _ in
            Task { @MainActor in self?.pendingSeek = nil }
        }

        if wasCrossfading { armCrossfadeBoundary() }
        updateNowPlayingInfo()
    }

    private struct PendingSeek {
        let target: TimeInterval
        let expiresAt: ContinuousClock.Instant
    }

    /// Where a seek sent the player, until it gets there or the deadline
    /// passes — whichever comes first.
    private var pendingSeek: PendingSeek?

    func setPlaybackRate(_ rate: Double) {
        playbackRate = rate
        if isPlaying {
            player?.rate = Float(rate)
        }
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

    /// Six seconds unless someone has said otherwise.
    ///
    /// `integer(forKey:)` cannot tell "off" from "never set", so the stored
    /// value is read through `object(forKey:)`: a fresh install gets the fade,
    /// and turning it off stays off.
    var crossfadeDuration: CrossfadeDuration = {
        guard let stored = UserDefaults.standard.object(forKey: "laxify.player.crossfade") as? Int
        else { return .s6 }
        return CrossfadeDuration(rawValue: stored) ?? .s6
    }()
    {
        didSet {
            UserDefaults.standard.set(crossfadeDuration.rawValue, forKey: "laxify.player.crossfade")
            // Applied to the track already playing, not just to the next one:
            // a setting that needs a track change to take effect reads as a
            // setting that does nothing.
            if crossfadeDuration == .off {
                cancelCrossfade()
            } else {
                armCrossfadeBoundary()
            }
        }
    }

    private var unplayableTrackIds: Set<String> = []

    /// The track already given a second chance after a transient failure, so
    /// one retry does not become a loop against a source that is properly out.
    private var retriedTrackId: String?

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

        // While a seek is in flight the player's own clock is still reporting
        // where it was, so anything drawn against it — the lyrics most
        // visibly — would lag and then snap. Answer with where it is going
        // until it is close enough that its own clock is the better answer,
        // or until the deadline says the seek is never going to confirm.
        if let pendingSeek {
            if ContinuousClock.now < pendingSeek.expiresAt, abs(seconds - pendingSeek.target) > 0.45 {
                return pendingSeek.target
            }
            self.pendingSeek = nil
        }

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
        // A new track starts with a clean clock, never one still answering
        // for wherever the last track's scrubber was pointed.
        pendingSeek = nil
        teardownPlayer()

        // The session goes live before the fetch, not after it. Until iOS has
        // been told this app is about to make sound, leaving the app during
        // the fetch suspends it — which is why tapping play and immediately
        // going to the home screen produced silence, while waiting for the
        // first note and then leaving worked.
        configureAudioSession()

        Task {
            // And an assertion to actually finish the fetch in the background.
            // Without it the network task is killed mid-flight; with it iOS
            // grants the seconds it takes to reach the first note.
            //
            // Held past this function, not released by a `defer` here: it
            // used to end the moment this closure returned, which was right
            // after handing the item to `awaitPlayback` and not after that
            // watchdog actually finished. Lock the phone in the gap — the
            // most ordinary thing to do right after tapping play — and iOS
            // suspended the process with nothing left telling it not to, so
            // a wait bounded at thirty-odd seconds only resumed counting once
            // the app was reopened. Every exit below ends it explicitly;
            // `awaitPlayback` takes ownership on the path that reaches it.
            let assertion = BackgroundAssertion("track-start")

            var trace = Trace("запуск трека", context: ["track": song.id])

            do {
                // Nothing is fetched before playback starts. A saved copy
                // plays from disk; anything else streams from our own server,
                // whose address is known without asking. Resolving a url first
                // and then having the server resolve it again was most of the
                // wait between a tap and the first sound.
                // Warmed while the previous track played, when there is one.
                // Written out rather than with `??`: the fallback is an async
                // throwing call, and an autoclosure cannot carry either.
                let item: AVPlayerItem
                let loader: StreamLoader?
                if let ready = takePrepared(for: song.id) {
                    (item, loader) = ready
                } else {
                    (item, loader) = try await Self.streamingItem(for: song.id, known: Self.known(song))
                }
                // Held so the download can be stopped when the track changes;
                // a loader with nothing referencing it is deallocated
                // mid-flight.
                streamLoader = loader
                trace.mark("ассет создан")

                guard currentSong?.id == song.id else {
                    AppLogger.log("play: song changed while loading, aborting")
                    assertion.end()
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
                // Ownership of `assertion` passes to this task — it, not the
                // closure returning here, decides when iOS may suspend again.
                Task { [weak self] in
                    await self?.awaitPlayback(of: item, for: song, trace: trace, assertion: assertion)
                }
                AppLogger.log("play: done")
            } catch {
                assertion.end()
                AppLogger.log("play: ERROR \(error)")
                trace.finish("ошибка")
                RemoteLog.shared.error(
                    "не удалось запустить трек",
                    category: "playback",
                    // Title and artist alongside the bare id — the id is
                    // what code needs, the name is what a person reading
                    // Випка actually recognises.
                    context: [
                        "track": song.id,
                        "title": song.title,
                        "artist": song.artistName,
                        "error": "\(error)",
                        "unplayable": "\(Self.isUnplayable(error))"
                    ]
                )
                isLoading = false
                isPlaying = false

                // A source that was throttling or briefly down said nothing
                // about this track, so it gets another go rather than being
                // struck off. One retry, and only for the track still in
                // front of the listener.
                if Self.isTransient(error), retriedTrackId != song.id {
                    retriedTrackId = song.id
                    RemoteLog.shared.warn(
                        "повторяем запуск после временного сбоя",
                        category: "playback",
                        context: ["track": song.id, "title": song.title]
                    )
                    Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(700))
                        guard let self, self.currentSong?.id == song.id else { return }
                        self.loadAndPlayCurrent()
                    }
                    return
                }

                // Some tracks in the source simply cannot be streamed. Stopping
                // dead on one of those makes a whole queue look broken, so move
                // on instead — the listener wanted music, not this exact track.
                if Self.isUnplayable(error), advancePastUnplayable(song) {
                    return
                }

                if error.isRegionBlocked {
                    errorMessage = "Трек недоступен с этим подключением — проверьте VPN"
                } else if error.isDRMProtected {
                    // Worth naming precisely even here, on the rare path
                    // where it is the last track in the queue rather than
                    // one skipped past: no VPN or retry fixes this one.
                    errorMessage = "Трек защищён правообладателем и недоступен для проигрывания"
                } else {
                    CrashReporter.report("Не удалось воспроизвести трек", detail: "\(error)")
                    errorMessage = "Не удалось воспроизвести трек"
                }
            }
        }
    }

    /// True when the source cannot produce a stream for this track at all,
    /// as opposed to the network being down.
    ///
    /// `notFound` belongs here and was missing, which is the whole reason
    /// some tracks never started: the direct resolve fails for a blocked or
    /// withdrawn upload, the proxy behind it is switched off, and what comes
    /// out is `notFound` — not a 502. It read as "something went wrong",
    /// so the player showed an error and sat on a track it was never going to
    /// play instead of moving to the next one.
    /// A failure that says nothing about the track and is worth one more go.
    private static func isTransient(_ error: Error) -> Bool {
        if case MusicServiceError.temporarilyUnavailable = error { return true }

        if case MusicServiceError.underlying(let underlying) = error,
           let urlError = underlying as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .cannotConnectToHost,
                 .dnsLookupFailed, .notConnectedToInternet, .cannotFindHost:
                return true
            default:
                return false
            }
        }

        return false
    }

    private static func isUnplayable(_ error: Error) -> Bool {
        // Checked first: a source that was merely busy must never be read as
        // a track that cannot exist.
        if isTransient(error) { return false }
        if case MusicServiceError.notFound = error { return true }
        if case MusicServiceError.drmProtected = error { return true }

        guard case MusicServiceError.underlying(let underlying) = error,
              case APIError.server(let status, _) = underlying else {
            return false
        }
        return status == 502 || status == 404 || status == 403
    }

    /// Skips to the next track that has not already failed.
    ///
    /// Returns false once the whole queue has been tried, so the caller can
    /// show a message rather than loop.
    private func advancePastUnplayable(_ song: Song) -> Bool {
        unplayableTrackIds.insert(song.id)

        // Tell the server, so this one stops being handed out. It checks
        // playability from where it runs, and the source answers differently
        // depending on where the asking is done — this device is the only one
        // that can say what actually happened here.
        let deadId = song.id
        Task { await LaxifyAPI.shared.reportUnplayable(trackIds: [deadId], reason: "клиент не смог открыть поток") }

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
    /// What the app already knows about a song, so a dead id is not the end
    /// of the road — the title and length are enough to find the same
    /// recording under a different upload.
    private static func known(_ song: Song) -> SoundCloudDirect.KnownTrack {
        SoundCloudDirect.KnownTrack(
            title: song.title, artist: song.artistName, duration: song.duration
        )
    }

    private static func streamingItem(
        for trackId: String, known: SoundCloudDirect.KnownTrack? = nil
    ) async throws -> (AVPlayerItem, StreamLoader?) {
        // A saved copy first, always. It starts instantly, it costs nothing,
        // and it is the only thing that plays when there is no network at all
        // — which is the entire point of having downloaded it.
        //
        // Then whatever was kept from an earlier listen. Same benefit, no
        // decision asked of anyone: a track heard once starts immediately the
        // next time.
        if let local = DownloadManager.localURL(for: trackId) ?? AudioCache.localURL(for: trackId) {
            let asset = AVURLAsset(url: local)
            return (AVPlayerItem(asset: asset), nil)
        }

        if let direct = try? await SoundCloudDirect.shared.streamURL(for: trackId, known: known) {
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
    /// The next track's player item, built while this one plays.
    ///
    /// Warming only the url left the expensive half — creating the asset and
    /// waiting for it to become playable — to happen after the tap, which is
    /// the pause between tracks. Building the whole item in advance means the
    /// tap has nothing left to wait for.
    private var prepared: (id: String, item: AVPlayerItem, loader: StreamLoader?)?

    private func prefetchNext() {
        guard queue.indices.contains(currentIndex + 1) else {
            prepared = nil
            return
        }
        let nextSong = queue[currentIndex + 1]
        let nextId = nextSong.id
        guard prepared?.id != nextId else { return }

        prepared = nil
        Task { [weak self] in
            do {
                let (item, loader) = try await Self.streamingItem(
                    for: nextId, known: Self.known(nextSong)
                )
                guard let self, self.queue.indices.contains(self.currentIndex + 1),
                      self.queue[self.currentIndex + 1].id == nextId
                else { return }

                // Nudges the asset into loading its first bytes now rather than
                // on first play.
                item.preferredForwardBufferDuration = 4
                self.prepared = (nextId, item, loader)
            } catch {
                // The next track cannot be played and we found out before the
                // listener reached it. Taking it out of the queue here is the
                // difference between a track that is never seen and one that
                // flashes up and vanishes — which is what "it skips" is.
                guard Self.isUnplayable(error) else { return }
                await self?.dropFromQueue(nextId, reason: "не открылся заранее")
            }
        }
    }

    /// Quietly removes a track that has already proven unplayable, and tells
    /// the server so it stops being handed out at all.
    private func dropFromQueue(_ trackId: String, reason: String) async {
        guard let index = queue.firstIndex(where: { $0.id == trackId }), index != currentIndex else {
            return
        }

        let song = queue[index]
        queue.remove(at: index)
        if index < currentIndex { currentIndex -= 1 }
        unplayableTrackIds.insert(trackId)

        RemoteLog.shared.warn(
            "трек убран из очереди до показа",
            category: "playback",
            context: [
                "track": trackId,
                "title": song.title,
                "artist": song.artistName,
                "причина": reason
            ]
        )

        await LaxifyAPI.shared.reportUnplayable(trackIds: [trackId], reason: reason)

        // The queue is one shorter; warm whatever moved up into the slot.
        prefetchNext()
    }

    /// The prepared item for a track, if it is the one we warmed and it has
    /// not been used already.
    private func takePrepared(for trackId: String) -> (AVPlayerItem, StreamLoader?)? {
        guard let prepared, prepared.id == trackId else { return nil }
        self.prepared = nil
        return (prepared.item, prepared.loader)
    }

    /// Waits for the item to be playable, and reports how long that took.
    ///
    /// Everything up to this point is bookkeeping; this is the part a
    /// listener experiences as the wait.
    /// Confirms the track that was just handed to `AVPlayer` actually makes
    /// sound, and moves on if it doesn't.
    ///
    /// This used to only log the two ways that can fail — the asset refusing
    /// to open, or thirty seconds passing with nothing ready — and then
    /// return, leaving `isPlaying` sitting at `true` over a track producing
    /// no audio at all with no error shown and nothing scheduled next. That
    /// silent hang, not a failure to start at all, is what "трек молчит"
    /// actually was: the early failure path (`loadAndPlayCurrent`'s own
    /// catch) only ever saw resolve errors, never an asset that resolved
    /// fine and then would not play.
    private func awaitPlayback(
        of item: AVPlayerItem, for song: Song, trace: Trace, assertion: BackgroundAssertion
    ) async {
        // Held for the whole wait, not just the resolve that preceded it —
        // see the comment where this was created.
        defer { assertion.end() }

        let deadline = ContinuousClock.now.advanced(by: .seconds(30))

        while ContinuousClock.now < deadline {
            // Overtaken by a later track — nothing here is still relevant.
            guard currentSong?.id == song.id else { return }

            if item.status == .failed {
                trace.finish("ассет не открылся")
                RemoteLog.shared.error(
                    "ассет не открылся",
                    category: "playback",
                    context: [
                        "track": song.id,
                        "title": song.title,
                        "artist": song.artistName,
                        "error": item.error.map { "\($0)" } ?? "неизвестно"
                    ]
                )
                failSilentTrack(song)
                return
            }

            if item.status == .readyToPlay, item.isPlaybackLikelyToKeepUp {
                trace.finish("звук пошёл")
                return
            }

            try? await Task.sleep(for: .milliseconds(50))
        }

        guard currentSong?.id == song.id else { return }

        trace.finish("не дождались")
        RemoteLog.shared.warn(
            "трек не начал играть за 30 с",
            category: "playback",
            context: ["track": song.id, "title": song.title, "artist": song.artistName]
        )
        failSilentTrack(song)
    }

    /// What happens to a track that reached the player and then produced
    /// nothing: treated exactly like one that never resolved at all — marked
    /// dead for this session and skipped, so the listener gets the next song
    /// instead of a silent one sitting under a "playing" label.
    private func failSilentTrack(_ song: Song) {
        isPlaying = false
        if !advancePastUnplayable(song) {
            errorMessage = "Не удалось воспроизвести трек"
        }
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

                // Half a minute in, this counts as a listen: keep a copy so
                // the next play starts instantly. Cheap to ask — it returns
                // immediately once the track is already here.
                if let song = self.currentSong {
                    AudioCache.note(song, playedFor: time.seconds)
                }

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
            guard let (item, loader) = try? await Self.streamingItem(for: nextSong.id, known: Self.known(nextSong)) else {
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
        pendingSeek = nil

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
        guard let sessionId = waveBatchId, !isExtendingWave, let lastId = queue.last?.id else { return }
        isExtendingWave = true
        defer { isExtendingWave = false }

        guard let batch = try? await CatalogService.shared.waveBatch(
            sessionId: sessionId, lastTrackId: lastId
        ), waveBatchId != nil else { return }

        // If the session had lapsed, the server opened a fresh one — follow it,
        // so feedback and the next top-up address a session that still exists.
        if batch.batchId != sessionId { waveBatchId = batch.batchId }

        // The server already spreads artists out and honours this session's
        // skips; second-guessing it here only thinned the batch unpredictably.
        let existing = Set(queue.map(\.id))
        let fresh = batch.songs.filter { !existing.contains($0.id) }
        guard !fresh.isEmpty else { return }

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
        let total = duration
        Task {
            await CatalogService.shared.reportWaveTrackFinished(
                trackId: trackId, batchId: batchId, playedSeconds: played, durationSeconds: total
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
