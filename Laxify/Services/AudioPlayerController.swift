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
    private(set) var isRefreshingWave = false
    private var lastWaveRefresh: Date?
    private static let waveRefreshInterval: TimeInterval = 20

    private var player: AVPlayer?
    private var timeObserverToken: Any?
    private var endObserver: NSObjectProtocol?
    /// Fires when the stream dies partway rather than reaching the end — see
    /// `handlePlaybackBroke`.
    private var breakObserver: NSObjectProtocol?
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
        pruneQueue()
    }

    /// Takes the tracks already proven unplayable out of the queue, before
    /// anyone gets to them.
    ///
    /// Only those. This used to also ask the source which tracks in the queue
    /// were blocked in this country and remove them — which was right while
    /// blocked meant silent, and is wrong now: a blocked track is played
    /// through the server from where it is not blocked, or found elsewhere.
    /// Removing them was removing songs that would have played. What is left
    /// in `UnplayableStore` is only what every route has already failed on.
    private func pruneQueue() {
        let playingId = currentSong?.id
        let known = queue.filter { UnplayableStore.contains($0.id) && $0.id != playingId }
        guard !known.isEmpty else { return }

        queue.removeAll { UnplayableStore.contains($0.id) && $0.id != playingId }
        if let playingId, let index = queue.firstIndex(where: { $0.id == playingId }) {
            currentIndex = index
        }
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

    /// Where the audio now playing came from, so a failure can be answered
    /// with the right thing — see `PreparedItem.Route`.
    private var currentRoute: PreparedItem.Route?

    /// Where a track that broke mid-play should pick up again, and how many
    /// times it has already been picked up. The count is what stops a stream
    /// that dies every thirty seconds from restarting forever.
    private var resumePoint: (id: String, seconds: TimeInterval, count: Int)?

    /// Tracks that have shown, this session, that the phone's own route gives
    /// less than the whole song — a preview, a stream that closes early, a
    /// connection that keeps breaking. They go through the server first for
    /// the rest of the session, rather than repeating the same short play
    /// every time they come round.
    private var serverFirstTrackIds: Set<String> = []
    /// Three, then the track moves on. A connection that cannot hold a stream
    /// for three goes is not going to hold it on the fourth, and by then the
    /// listener has been staring at a stopped player for a while.
    private static let maxResumes = 3

    /// Counts every time a player is put together, so a watchdog left over
    /// from a previous one can tell that it is watching something nobody is
    /// listening to.
    ///
    /// The track id is not enough on its own: a retry, and a resume after a
    /// broken stream, both open the *same* track again, and the watchdog from
    /// the abandoned attempt would happily go on to declare that track dead
    /// on behalf of an item that has already been replaced.
    private var loadGeneration = 0

    /// Whether `duration` is the length the player read out of the file, as
    /// opposed to the length the catalogue claims. Nothing that ends a track
    /// early may act on the claim.
    private var durationIsConfirmed = false

    /// The row on disk for the listen in progress, updated as it goes rather
    /// than written once at the end — see `checkpointPlayback`.
    private var currentPlayRecord: PlayRecord?
    private var lastCheckpointAt: TimeInterval = 0
    private static let checkpointInterval: TimeInterval = 30

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
        discardPrepared()
        queue = []
        currentIndex = 0
        currentSong = nil
        currentRoute = nil
        resumePoint = nil
        serverFirstTrackIds.removeAll()
        currentTime = 0
        duration = 0
        durationIsConfirmed = false
        isPlaying = false
        isLoading = false
        errorMessage = nil
        waveBatchId = nil
        unplayableTrackIds.removeAll()
        LiveActivityController.shared.stop()
        updateNowPlayingInfo()
    }

    /// - Parameter attempt: which go this is. Zero is the ordinary one; the
    ///   rest are the player quietly trying the other ways in before anyone
    ///   is told a track will not play. See `retryOrGiveUp`.
    private func loadAndPlayCurrent(attempt: Int = 0) {
        guard queue.indices.contains(currentIndex) else { return }
        cancelCrossfade()
        let song = queue[currentIndex]
        AppLogger.log("play: start id=\(song.id) title=\(song.title) attempt=\(attempt)")
        CrashReporter.breadcrumb("play start \(song.id)")
        // Only the track that broke gets put back where it was; moving to any
        // other one starts it from the top, as it should.
        if resumePoint?.id != song.id { resumePoint = nil }
        loadGeneration &+= 1
        let generation = loadGeneration
        currentSong = song
        extendWaveQueueIfNeeded()
        currentTime = 0
        duration = song.duration
        // The length is the source's estimate until the player has read the
        // file itself. Nothing that cuts a track short may run off an
        // estimate — see `armCrossfadeBoundary`.
        durationIsConfirmed = false
        isLoading = true
        errorMessage = nil
        // A new listen writes its own row; the previous track's must not be
        // topped up with this one's seconds.
        currentPlayRecord = nil
        lastCheckpointAt = 0
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
                //
                // Only ever on the first go. A retry exists because something
                // about the last attempt was wrong, and a warmed item is one
                // of the things it could have been.
                let ready: PreparedItem
                if attempt == 0, !serverFirstTrackIds.contains(song.id),
                   let warmed = takePrepared(for: song.id) {
                    ready = warmed
                } else {
                    ready = try await Self.streamingItem(
                        for: song.id,
                        known: Self.known(song),
                        // A file on this device that has just refused to play
                        // is the one thing not worth trying twice.
                        allowingLocal: attempt == 0,
                        // The phone's own route has had two goes by now; the
                        // server's is a different connection entirely.
                        preferringProxy: attempt >= 2 || serverFirstTrackIds.contains(song.id)
                    )
                }
                let item = ready.item
                trace.mark("ассет создан")

                // Checked before anything of this track's is written down.
                // Assigning first and checking after meant a track that had
                // already been skipped past could overwrite the *live*
                // track's loader on its way out, leaving the one actually
                // playing with nothing holding it.
                guard currentSong?.id == song.id, generation == loadGeneration else {
                    AppLogger.log("play: song changed while loading, aborting")
                    ready.loader?.cancel()
                    assertion.end()
                    return
                }

                // Held so the download can be stopped when the track changes;
                // a loader with nothing referencing it is deallocated
                // mid-flight.
                streamLoader = ready.loader
                currentRoute = ready.route
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
                    await self?.awaitPlayback(
                        of: item,
                        for: song,
                        attempt: attempt,
                        generation: generation,
                        trace: trace,
                        assertion: assertion
                    )
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
                        "попытка": "\(attempt)",
                        "error": "\(error)",
                        "окончательно": "\(Self.isFinal(error))"
                    ]
                )
                isLoading = false
                isPlaying = false
                retryOrGiveUp(song, error: error, attempt: attempt)
            }
        }
    }

    /// How many goes a track gets before the listener is told anything.
    ///
    /// Three, and they are three genuinely different goes rather than the
    /// same one repeated: the first is however the track was warmed, the
    /// second re-resolves from the source ignoring anything cached on this
    /// device, the third comes through our own server on a different
    /// connection entirely. Roughly three seconds end to end, which is less
    /// than the pause a listener already expects at a track change.
    private static let maxAttempts = 3
    /// A verdict the source has already given and substitution has already
    /// failed to overturn. Trying that twice more is three seconds of nothing
    /// for a certain answer, so it gets one confirming go and no more.
    private static let maxAttemptsWhenFinal = 2

    /// Tries again, and only calls a track dead once there is nothing left to
    /// try.
    ///
    /// This replaced a single retry that could never actually fire. It was
    /// guarded on the error being transient, and by the time an error reached
    /// it every failure in the app had been flattened into `notFound` — so
    /// the branch was dead code, and the branch below it, the one that skips
    /// the track and writes it off, took every failure in the app.
    private func retryOrGiveUp(_ song: Song, error: Error?, attempt: Int) {
        let failure = error ?? MusicServiceError.notFound
        let final = Self.isFinal(failure)
        let allowed = final ? Self.maxAttemptsWhenFinal : Self.maxAttempts

        if attempt + 1 < allowed {
            // Short, and getting longer: a source that is throttling wants a
            // moment, and a stale signature wants nothing but a second ask.
            let pause = [250, 900, 1800][min(attempt, 2)]
            RemoteLog.shared.warn(
                "пробуем трек ещё раз",
                category: "playback",
                context: [
                    "track": song.id,
                    "title": song.title,
                    "попытка": "\(attempt + 1)",
                    "пауза_мс": "\(pause)"
                ]
            )
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(pause))
                guard let self, self.currentSong?.id == song.id else { return }
                self.loadAndPlayCurrent(attempt: attempt + 1)
            }
            return
        }

        // Everything has been tried. Only now is anything written down, and
        // only a verdict the source actually gave is written down as one; the
        // rest is a strike, which takes three separate occasions to hide a
        // track and lets it go again after an afternoon.
        if final {
            UnplayableStore.remember(song.id)
        } else {
            UnplayableStore.strike(song.id)
        }

        if advancePastUnplayable(song, definitive: final) { return }

        if failure.isRegionBlocked {
            errorMessage = "Трек недоступен с этим подключением — проверьте VPN"
        } else if failure.isDRMProtected {
            // Worth naming precisely even here, on the rare path
            // where it is the last track in the queue rather than
            // one skipped past: no VPN or retry fixes this one.
            errorMessage = "Трек защищён правообладателем и недоступен для проигрывания"
        } else {
            CrashReporter.report("Не удалось воспроизвести трек", detail: "\(failure)")
            errorMessage = "Не удалось воспроизвести трек"
        }
    }

    /// A failure that says nothing about the track and is worth another go.
    private static func isTransient(_ error: Error) -> Bool {
        SoundCloudDirect.isTransient(error)
    }

    /// True only when the source itself has answered and the answer settles
    /// the matter: this recording has no copy anywhere that will play.
    ///
    /// The bar is deliberately high, because everything downstream of this
    /// is irreversible-feeling to a listener — the track is skipped, hidden
    /// from listings, and reported to the server so it stops being handed to
    /// anyone. The previous version of this returned true for a bare
    /// `notFound`, and `notFound` was what every failure in the app had been
    /// flattened into by the time it arrived, so all of that happened over
    /// dropped connections. A refusal we cannot explain is now not final; it
    /// costs the track a strike and nothing more.
    private static func isFinal(_ error: Error) -> Bool {
        // Checked first: a source that was merely busy must never be read as
        // a track that cannot exist.
        if isTransient(error) { return false }

        // Two verdicts settle anything on their own, both reached only after
        // the source has actually answered: DRM-only (no client outside the
        // source can ever open it) and confirmedUnavailable (resolve failed
        // *and* a rescue search found nothing safe). Everything else this
        // file threw as a bare `notFound` used to fall into this branch too,
        // which is exactly what let a dropped connection get read as "this
        // song does not exist" — see MusicServiceError.confirmedUnavailable.
        if case MusicServiceError.drmProtected = error { return true }
        if case MusicServiceError.confirmedUnavailable = error { return true }

        // A locked recording is not final any more, and was the commonest
        // reason a song was skipped: the server now finds the same recording
        // elsewhere. The remaining verdict that settles anything here is the
        // server's own "found nowhere", which arrives as its 404.
        guard case MusicServiceError.underlying(let underlying) = error,
              case APIError.server(let status, _) = underlying else {
            return false
        }
        return status == 404 || status == 410
    }

    /// Skips to the next track that has not already failed.
    ///
    /// Returns false once the whole queue has been tried, so the caller can
    /// show a message rather than loop.
    ///
    /// - Parameter definitive: whether the source actually said this track is
    ///   dead. Only then is the server told. It hands out this track to
    ///   everyone, and a report there is not undone by the next launch the
    ///   way a local one is — telling it "unplayable" because one phone spent
    ///   thirty seconds on a bad connection is how a working song leaves the
    ///   catalogue for every listener at once.
    private func advancePastUnplayable(_ song: Song, definitive: Bool) -> Bool {
        unplayableTrackIds.insert(song.id)

        if definitive {
            // Tell the server, so this one stops being handed out. It checks
            // playability from where it runs, and the source answers
            // differently depending on where the asking is done — this device
            // is the only one that can say what actually happened here.
            let deadId = song.id
            Task {
                await LaxifyAPI.shared.reportUnplayable(
                    trackIds: [deadId], reason: "источник: играть нечего"
                )
            }
        }

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

    /// An item, where it came from, and when it was made.
    ///
    /// The route matters after the fact. An item built from a file on this
    /// device that then refuses to play means the file is bad and should go;
    /// the same refusal from a signed url means the signature is stale and
    /// the answer is to resolve it again. Both used to be read as "this
    /// track does not play", which is neither.
    ///
    /// The timestamp matters because a signed url does not keep. One resolved
    /// while the previous track was starting can be refused by the time that
    /// track ends — a skip five minutes after the mistake that caused it, and
    /// impossible to account for from the outside.
    private struct PreparedItem {
        enum Route {
            case download, cache, direct, proxy

            /// Whether what this points at is a file that will still be there
            /// tomorrow, as opposed to a link that expires.
            var isLocal: Bool { self == .download || self == .cache }
            var expires: Bool { self == .direct }
        }

        let item: AVPlayerItem
        let loader: StreamLoader?
        let route: Route
        let madeAt: Date

        /// Two minutes. Comfortably inside the shortest signature the source
        /// has been seen to issue, and long enough that the ordinary case —
        /// warmed a track ahead, played a track and a bit — is still a
        /// warmed start rather than a resolve.
        var isStale: Bool {
            route.expires && Date().timeIntervalSince(madeAt) > 120
        }
    }

    /// Opens a track, by whichever route will answer.
    ///
    /// - Parameters:
    ///   - allowingLocal: false on a retry. A copy on disk is tried first
    ///     because it is instant and works offline, but a copy that has just
    ///     failed to play is precisely the thing not to try again.
    ///   - preferringProxy: true on a late retry. The two routes fail for
    ///     unrelated reasons — one is the phone's own connection to the
    ///     source, the other is our server's — so a track the first cannot
    ///     open is often waiting behind the second.
    ///
    /// Whatever went wrong is thrown as it happened. The version of this that
    /// wrote `try?` here and then threw a flat `notFound` is the single
    /// reason working songs were struck off: every timeout, every throttled
    /// minute and every dropped connection arrived at the player wearing the
    /// same face as a withdrawn upload, and the player believed it.
    private static func streamingItem(
        for trackId: String,
        known: SoundCloudDirect.KnownTrack? = nil,
        allowingLocal: Bool = true,
        preferringProxy: Bool = false
    ) async throws -> PreparedItem {
        // A saved copy first, always. It starts instantly, it costs nothing,
        // and it is the only thing that plays when there is no network at all
        // — which is the entire point of having downloaded it.
        //
        // Then whatever was kept from an earlier listen. Same benefit, no
        // decision asked of anyone: a track heard once starts immediately the
        // next time.
        if allowingLocal {
            if let saved = DownloadManager.localURL(for: trackId) {
                return PreparedItem(
                    item: AVPlayerItem(asset: AVURLAsset(url: saved)),
                    loader: nil, route: .download, madeAt: Date()
                )
            }
            if let cached = AudioCache.localURL(for: trackId) {
                return PreparedItem(
                    item: AVPlayerItem(asset: AVURLAsset(url: cached)),
                    loader: nil, route: .cache, madeAt: Date()
                )
            }
        }

        // The first thing that went wrong, kept so it can be thrown rather
        // than replaced by a tidier-looking one further down.
        var refusal: Error?

        func openDirect() async -> PreparedItem? {
            do {
                let url = try await SoundCloudDirect.shared.streamURL(for: trackId, known: known)
                DirectRouteHealth.succeeded()
                let asset = AVURLAsset(
                    url: url,
                    // Lets the player start on what has arrived instead of
                    // waiting for a comfortable buffer.
                    options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
                )
                return PreparedItem(
                    item: AVPlayerItem(asset: asset), loader: nil, route: .direct, madeAt: Date()
                )
            } catch {
                if refusal == nil { refusal = error }
                if Self.isTransient(error) { DirectRouteHealth.failed() }
                return nil
            }
        }

        // Slower, but it is the route that can play anything: the server
        // reaches the source from another country, and when the source will
        // not serve a track at all it finds the same recording elsewhere.
        func openProxy() async -> PreparedItem? {
            guard let proxy = await LaxifyAPI.shared.proxyAudioRequest(
                trackId: trackId,
                title: known?.title,
                artist: known?.artist,
                duration: known?.duration
            ) else {
                return nil
            }

            let loader = StreamLoader(
                source: proxy.url,
                headers: proxy.headers,
                usesPinnedTrust: await LaxifyAPI.shared.routeNeedsPinnedTrust
            )

            return PreparedItem(
                item: AVPlayerItem(asset: loader.makeAsset()),
                loader: loader, route: .proxy, madeAt: Date()
            )
        }

        // The server first when asked for, and also when the phone's own
        // connection to the source has just been failing: on a network that
        // interferes with that connection every direct attempt costs its full
        // timeout before giving way, and those seconds were most of the
        // "track did not start in thirty seconds" in the logs.
        if preferringProxy || DirectRouteHealth.isDegraded {
            if let viaServer = await openProxy() { return viaServer }
            if let viaSource = await openDirect() { return viaSource }
        } else {
            if let viaSource = await openDirect() { return viaSource }

            // Every refusal goes on to the server, a locked recording
            // included. That one used to stop here, on the reasoning that the
            // server hits the same lock — which it does, and which is exactly
            // why the server no longer stops at the lock: it finds the song
            // somewhere else. Stopping here was what made those tracks skip.
            if let viaServer = await openProxy() { return viaServer }
        }

        throw refusal ?? MusicServiceError.notFound
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
    private var prepared: (id: String, ready: PreparedItem)?

    private func prefetchNext() {
        guard queue.indices.contains(currentIndex + 1) else {
            discardPrepared()
            return
        }
        let nextSong = queue[currentIndex + 1]
        let nextId = nextSong.id
        guard prepared?.id != nextId else { return }

        discardPrepared()
        Task { [weak self] in
            do {
                let ready = try await Self.streamingItem(for: nextId, known: Self.known(nextSong))
                guard let self, self.queue.indices.contains(self.currentIndex + 1),
                      self.queue[self.currentIndex + 1].id == nextId
                else {
                    // Warmed for a track nobody is going to reach any more.
                    // The proxy route starts downloading the moment its asset
                    // is made, so this has to be stopped rather than dropped.
                    ready.loader?.cancel()
                    return
                }

                // Nudges the asset into loading its first bytes now rather than
                // on first play.
                ready.item.preferredForwardBufferDuration = 4
                self.prepared = (nextId, ready)
            } catch {
                // Deliberately nothing. This used to take the track out of
                // the queue, on the reasoning that a track removed before it
                // is seen beats one that flashes up and vanishes — but the
                // premise was that failing to warm meant the track was dead,
                // and it does not. Warming happens the instant the previous
                // track starts, which is exactly when the connection is
                // busiest and the source most likely to throttle, so the
                // failures this collected were mostly good songs caught at a
                // bad moment. They are now left where they are and opened
                // properly when their turn comes, with retries behind them.
                RemoteLog.shared.info(
                    "не удалось прогреть следующий трек",
                    category: "playback",
                    context: ["track": nextId, "title": nextSong.title, "error": "\(error)"]
                )
                // No exceptions any more, a locked recording included: when
                // its turn comes it goes to the server, which finds it
                // elsewhere. Taking it out of the queue here was taking out a
                // song that would have played.
            }
        }
    }

    /// Lets go of a warmed item, stopping anything it had already started.
    private func discardPrepared() {
        prepared?.ready.loader?.cancel()
        prepared = nil
    }

    /// The prepared item for a track, if it is the one we warmed and it has
    /// not been used already.
    private func takePrepared(for trackId: String) -> PreparedItem? {
        guard let prepared, prepared.id == trackId else { return nil }
        self.prepared = nil

        guard !prepared.ready.isStale else {
            // Warmed a while back, pointing at a signature that has very
            // likely lapsed since. Using it costs a failed start and a skip;
            // not using it costs one resolve, which is the cheaper mistake by
            // a wide margin.
            prepared.ready.loader?.cancel()
            RemoteLog.shared.info(
                "прогретая ссылка устарела, открываем заново",
                category: "playback",
                context: ["track": trackId]
            )
            return nil
        }

        return prepared.ready
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
        of item: AVPlayerItem,
        for song: Song,
        attempt: Int,
        generation: Int,
        trace: Trace,
        assertion: BackgroundAssertion
    ) async {
        // Held for the whole wait, not just the resolve that preceded it —
        // see the comment where this was created.
        defer { assertion.end() }

        // The wait is measured against progress, not against the clock. A
        // fixed thirty seconds is a fine limit for a track that is doing
        // nothing and a cruel one for a track that is loading slowly — and
        // the second is far more common on the connections this app is
        // actually used on. So: twenty quiet seconds ends it, but any sign of
        // life resets that, up to a ceiling that stops a trickle from holding
        // the queue forever.
        // Through the server the first byte can legitimately be a while
        // coming: a track the source will not serve is being found elsewhere
        // and fetched before any of it exists to send. Twenty silent seconds
        // is a dead connection on the direct route and an ordinary rescue on
        // this one.
        let quietWindow: Duration = currentRoute == .proxy ? .seconds(45) : .seconds(20)
        var quietUntil = ContinuousClock.now.advanced(by: quietWindow)
        let ceiling = ContinuousClock.now.advanced(by: .seconds(120))
        var seenBuffered: Double = -1

        while ContinuousClock.now < quietUntil, ContinuousClock.now < ceiling {
            // Overtaken by a later track, or by a later go at this same one —
            // nothing here is still relevant either way.
            guard currentSong?.id == song.id, generation == loadGeneration else { return }

            if item.status == .failed {
                trace.finish("ассет не открылся")
                RemoteLog.shared.error(
                    "ассет не открылся",
                    category: "playback",
                    context: [
                        "track": song.id,
                        "title": song.title,
                        "artist": song.artistName,
                        "маршрут": "\(currentRoute.map { "\($0)" } ?? "-")",
                        "попытка": "\(attempt)",
                        "error": item.error.map { "\($0)" } ?? "неизвестно"
                    ]
                )
                failedToPlay(song, error: item.error, attempt: attempt)
                return
            }

            // Ready is enough. Requiring `isPlaybackLikelyToKeepUp` as well
            // meant a track that could already make sound was still counted
            // as not started, and on a link that never quite convinces
            // AVPlayer it will keep up — a phone on one bar, most evenings —
            // twenty seconds of that ended with a perfectly good song being
            // skipped and reported dead. Whether it keeps up afterwards is a
            // stall, which the player handles on its own.
            if item.status == .readyToPlay {
                trace.finish("звук пошёл")
                // It played. Whatever this track was carrying against it, it
                // has earned its way out of.
                UnplayableStore.absolve(song.id)

                // A track re-opened after its stream broke goes back to where
                // it stopped. Done here rather than the moment the item was
                // handed over: a seek asked of an item that is not ready yet
                // is quietly dropped, and the track would restart from the
                // beginning — which is its own kind of infuriating.
                if let resume = resumePoint, resume.id == song.id, resume.seconds > 1 {
                    seek(to: resume.seconds)
                }
                return
            }

            // Bytes arriving, or a listener who has paused, both mean the
            // silence is not the track's fault.
            let buffered = item.loadedTimeRanges.first
                .map { CMTimeGetSeconds($0.timeRangeValue.duration) } ?? 0
            if buffered > seenBuffered || !isPlaying {
                seenBuffered = buffered
                quietUntil = ContinuousClock.now.advanced(by: quietWindow)
            }

            try? await Task.sleep(for: .milliseconds(50))
        }

        guard currentSong?.id == song.id, generation == loadGeneration else { return }

        trace.finish("не дождались")
        RemoteLog.shared.warn(
            "трек так и не начал играть",
            category: "playback",
            context: [
                "track": song.id,
                "title": song.title,
                "artist": song.artistName,
                "попытка": "\(attempt)"
            ]
        )
        failedToPlay(song, error: nil, attempt: attempt)
    }

    /// What happens to a track that reached the player and then produced
    /// nothing.
    ///
    /// It used to be skipped on the spot. Now it goes back through the same
    /// ladder as a track that never opened at all — which matters most here,
    /// because the commonest cause of a silent item is not a dead track but a
    /// signature that expired between being warmed and being used, and that
    /// is fixed by asking again.
    private func failedToPlay(_ song: Song, error: Error?, attempt: Int) {
        isPlaying = false
        isLoading = false

        // A file on this device that will not open is a bad file. It was
        // written from whatever the source returned at the time, and if that
        // was a refusal rather than audio then this track could never play
        // again — the copy is found first, every time, and the weekly sweep
        // was the only thing that ever cleared it.
        if currentRoute == .cache {
            AudioCache.forget(song.id)
            RemoteLog.shared.warn(
                "сохранённая копия испорчена, удалена",
                category: "playback",
                context: ["track": song.id, "title": song.title]
            )
        } else if currentRoute == .download {
            // Not deleted here: a download is something the listener asked
            // for and can see, and removing it from under them belongs on
            // that screen, not in the player. The retry below streams
            // instead, so the track still plays.
            RemoteLog.shared.warn(
                "скачанный файл не открывается",
                category: "playback",
                context: ["track": song.id, "title": song.title]
            )
        } else if currentRoute == .direct, DirectRouteHealth.isNetworkFailure(error) {
            // The phone reached the source's api but not its media host —
            // what an interfering network does most often. Counted, so the
            // next track goes through the server first.
            DirectRouteHealth.failed()
        }

        // The loader's own reason outranks the player's. What the player
        // reports for a server answer is its generic "the media may be
        // damaged", which cannot tell a dropped connection from the server
        // having looked everywhere and found nothing — and only the second
        // of those should ever end a track's chances.
        let reason = streamLoader?.failureReason ?? error

        teardownPlayer()
        retryOrGiveUp(song, error: reason, attempt: attempt)
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
                self.checkpointPlayback()
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

        // The other way a track ends: it breaks. Nothing was listening for
        // this, and AVPlayer's response to a stream that dies mid-track is
        // simply to stop — so a track played for two minutes and then went
        // quiet under a "playing" label, and the next thing the listener did
        // was press skip. That is a skip the app caused and never saw.
        breakObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] note in
            // Read out here, as text: what crosses into the task has to be
            // something that can safely cross, and the reason is only ever
            // going into a log line anyway.
            let reason = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)
                .map { "\($0)" }
            Task { @MainActor in self?.handlePlaybackBroke(reason) }
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
                guard let self, let song = self.currentSong else { return }
                guard seconds.isFinite, seconds > 1 else { return }

                // The player's reading is normally the better one — except
                // when it is much shorter than the length the catalogue
                // carries. An mp3 opened without precise timing is measured
                // from its header, and a variable-rate file with no seek
                // table is measured wrong; believing that reading ends the
                // track wherever the header happened to point, which is a
                // song cut off two thirds of the way through and the next
                // one starting. Five seconds of slack, because a substituted
                // upload is matched to within five.
                let claimed = song.duration
                guard claimed <= 0 || seconds >= claimed - 5 else {
                    RemoteLog.shared.warn(
                        "плеер называет длину короче каталога — не верим",
                        category: "playback",
                        context: [
                            "track": song.id,
                            "плеер": "\(Int(seconds))",
                            "каталог": "\(Int(claimed))"
                        ]
                    )
                    return
                }

                // Set even when the number matches what the catalogue said.
                // It is not the value that was missing before, it is the
                // confirmation: until this fires, `duration` is a claim, and
                // the fade below cuts a track short if it acts on a claim
                // that happens to be four seconds under.
                self.durationIsConfirmed = true
                if abs(self.duration - seconds) > 1 { self.duration = seconds }
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
              // Never off the catalogue's estimate. A substituted upload is
              // matched to within five seconds, and an mp3 opened without
              // precise timing reports its own length approximately — so a
              // boundary placed on the estimate can sit fifteen seconds
              // before the actual end, which is not a crossfade, it is the
              // track being cut off. That is what "it skipped" was on tracks
              // that had started perfectly well.
              durationIsConfirmed,
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
              // Same reason as `armCrossfadeBoundary`: a fade started off a
              // length nobody has verified ends the track wherever that
              // length happens to be wrong.
              durationIsConfirmed,
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

            // The warmed item first. It was made for exactly this track and
            // is the whole reason warming exists; resolving a second copy
            // here meant every fade cost an extra pair of requests to a
            // source that answers a throttle to too many of them — and being
            // throttled is what makes the *next* track fail to open.
            let ready: PreparedItem
            if let warmed = self.takePrepared(for: nextSong.id) {
                ready = warmed
            } else if let opened = try? await Self.streamingItem(
                for: nextSong.id, known: Self.known(nextSong)
            ) {
                ready = opened
            } else {
                self.abortCrossfade()
                return
            }

            await self.runCrossfade(to: nextSong, ready: ready, over: ramp)
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
        to song: Song, ready preparedItem: PreparedItem, over ramp: Double
    ) async {
        let item = preparedItem.item
        let outgoing = player
        let incoming = AVPlayer(playerItem: item)
        incoming.volume = 0
        incoming.automaticallyWaitsToMinimizeStalling = true
        crossfadePlayer = incoming

        // Wait until the incoming track can actually produce sound. Ramping
        // before it is ready fades the current track down into a gap and then
        // slams the next one in at full volume — which is what "crossfade
        // doesn't work" looked like.
        let isReady = await Self.waitUntilReady(item, timeout: 3.0)
        guard !Task.isCancelled else { incoming.pause(); return }
        guard isReady else {
            // Nothing lost: the current track keeps playing to its own end
            // and the ordinary handler opens the next one properly, with the
            // retries behind it. The one thing that must not happen is this
            // half-opened item being left running.
            preparedItem.loader?.cancel()
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
        // A different player is now the one that matters; anything still
        // watching the last one is watching nothing.
        loadGeneration &+= 1
        player = incoming
        crossfadePlayer = nil
        streamLoader = preparedItem.loader
        currentRoute = preparedItem.route
        incoming.volume = 1

        currentIndex += 1
        currentSong = song
        currentTime = 0
        duration = song.duration
        durationIsConfirmed = false
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

    /// The stream died while the track was playing.
    ///
    /// AVPlayer reports this once and then does nothing, which is how a track
    /// came to play for two minutes and stop — the app still showing it as
    /// playing, the listener eventually pressing skip. From the outside that
    /// is indistinguishable from the app skipping by itself, and it is the
    /// half of "tracks get skipped" that happens *after* a track has started
    /// perfectly well.
    ///
    /// Answered by opening the track again and putting the playhead back
    /// where it stopped, so what a listener notices is a pause rather than a
    /// lost song.
    private func handlePlaybackBroke(_ reason: String?, endedEarly: Bool = false) {
        guard let song = currentSong, !isCrossfading else { return }

        // Near enough to the end to be the end. Some streams simply stop
        // rather than closing cleanly, and treating that as a break would
        // replay the last seconds of every such track. Not asked when the
        // caller already knows the track ended early — that is the question
        // it has just answered the other way.
        if !endedEarly, durationIsConfirmed, duration > 0, currentTime >= duration - 1.5 {
            handleDidFinishPlaying()
            return
        }

        // A break on the phone's own route is resumed through the server.
        // The connection that broke is the one most likely to break again,
        // and a preview or a truncated file will be exactly as short the
        // second time it is fetched from the same place.
        if currentRoute != .proxy {
            serverFirstTrackIds.insert(song.id)
            if currentRoute == .cache { AudioCache.forget(song.id) }
        }

        let already = resumePoint?.id == song.id ? (resumePoint?.count ?? 0) : 0
        let at = currentTime

        RemoteLog.shared.warn(
            "поток оборвался посреди трека",
            category: "playback",
            context: [
                "track": song.id,
                "title": song.title,
                "секунда": "\(Int(at))",
                "из": "\(Int(duration))",
                "восстановлений": "\(already)",
                "причина": reason ?? "неизвестно"
            ]
        )

        guard already < Self.maxResumes else {
            resumePoint = nil
            isPlaying = false
            updateNowPlayingInfo()
            _ = advancePastUnplayable(song, definitive: false)
            return
        }

        resumePoint = (song.id, at, already + 1)
        // Attempt one, not zero: whatever this track was opened with has just
        // proven itself, so the warmed item and any copy on disk are skipped
        // and the link is resolved afresh.
        loadAndPlayCurrent(attempt: 1)
    }

    private func handleDidFinishPlaying() {
        // A crossfade already advanced the queue; the end-of-item on the old
        // player is nothing to act on.
        if isCrossfading { return }

        // Ended well short of its length. That is not a track finishing, it
        // is a thirty-second preview or a stream that closed as though it had
        // — and the player reports both as a perfectly normal end, so they
        // went straight to the next song. From the outside: half a minute of
        // a track, then a skip nobody asked for. Picked up where it stopped,
        // through the server, which has the whole recording.
        let expected = currentSong?.duration ?? 0
        if repeatMode != .one, currentRoute != .proxy,
           expected > 45, currentTime > 1, currentTime < expected - 15 {
            RemoteLog.shared.warn(
                "трек закончился раньше времени",
                category: "playback",
                context: [
                    "track": currentSong?.id ?? "-",
                    "title": currentSong?.title ?? "-",
                    "секунда": "\(Int(currentTime))",
                    "из": "\(Int(expected))",
                    "маршрут": "\(currentRoute.map { "\($0)" } ?? "-")"
                ]
            )
            handlePlaybackBroke("закончился раньше времени", endedEarly: true)
            return
        }

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

    /// Makes the queue already playing into the wave, once its session exists.
    ///
    /// For a track started from the wave's deck in the moment before the
    /// session had arrived. It carries on untouched; from here on its skips
    /// and finishes are reported, and the queue tops itself up like any wave.
    func adoptWaveSession(_ batchId: String) {
        guard waveBatchId == nil, currentSong != nil else { return }
        waveBatchId = batchId
        if let song = currentSong { reportWaveStart(for: song) }
        extendWaveQueueIfNeeded()
    }

    /// Rebuilds everything after the current track server-side; `reshapeWaveTail`
    /// only tops up, so the server would hand back the tail it already had.
    func refreshWaveTail() {
        guard let sessionId = waveBatchId, let current = currentSong, !isExtendingWave else { return }
        if let lastWaveRefresh, Date().timeIntervalSince(lastWaveRefresh) < Self.waveRefreshInterval {
            return
        }
        lastWaveRefresh = Date()
        isExtendingWave = true
        isRefreshingWave = true

        Task {
            defer {
                isExtendingWave = false
                isRefreshingWave = false
            }
            guard let batch = try? await CatalogService.shared.waveBatch(
                sessionId: sessionId, lastTrackId: current.id, refresh: true
            ), waveBatchId != nil else { return }

            if batch.batchId != sessionId { waveBatchId = batch.batchId }

            // A fade already carries the old next track; swapping it now would desync the queue.
            guard !isCrossfading, queue.indices.contains(currentIndex) else { return }
            let kept = Array(queue[...currentIndex])
            let keptIds = Set(kept.map(\.id))
            let fresh = batch.songs.filter { !keptIds.contains($0.id) }
            guard !fresh.isEmpty else { return }
            queue = kept + fresh
        }
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
        //
        // Updates the row the checkpoints below have been keeping rather than
        // adding a second one for the same listen.
        currentPlayRecord = LocalReplay.upsert(
            song,
            seconds: currentTime,
            completed: completed,
            into: currentPlayRecord,
            context: modelContext
        )

        let context = modelContext
        Task { await PlaybackUploader.flush(context: context) }
    }

    /// Writes down a listen that is still going.
    ///
    /// Called from the playback clock. Without it nothing existed until a
    /// track ended or was skipped: five minutes into an album the statistics
    /// screen was still empty, and closing the app in the middle lost the
    /// listening entirely. Half a minute apart — often enough that little is
    /// ever at risk, rare enough to be free.
    private func checkpointPlayback() {
        guard let song = currentSong, currentTime > Self.checkpointInterval else { return }
        guard currentTime - lastCheckpointAt >= Self.checkpointInterval else { return }

        lastCheckpointAt = currentTime
        currentPlayRecord = LocalReplay.upsert(
            song,
            seconds: currentTime,
            completed: false,
            into: currentPlayRecord,
            context: modelContext
        )
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
        if let breakObserver {
            NotificationCenter.default.removeObserver(breakObserver)
        }
        breakObserver = nil
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
