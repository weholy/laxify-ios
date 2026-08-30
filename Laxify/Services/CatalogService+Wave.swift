import Foundation

/// The wave, served by the backend as a running session.
///
/// The server holds the session (its `sessionId` is what we thread through as
/// `batchId`): it remembers what was skipped and finished *this sitting* and
/// reshapes what comes next from that. So the feedback calls below are no
/// longer no-ops — a skip or a finish actually moves the next batch.
extension CatalogService {
    /// Fetches the next run.
    ///
    /// With no `sessionId` this opens a fresh session (`/wave/start`). With
    /// one, it advances that session's chain (`/wave/next`) — `lastTrackId` is
    /// the track just left, so the buffer tops up after it rather than
    /// replaying what was already heard. A lapsed session falls back to a new
    /// one so the music never stops on a 409.
    func waveBatch(sessionId: String? = nil, lastTrackId: String? = nil) async throws -> WaveBatch {
        let settings = WaveSettings.load()

        do {
            let dto: WaveSessionDTO
            if let sessionId {
                if let advanced = try? await LaxifyAPI.shared.waveNext(
                    sessionId: sessionId, lastTrackId: lastTrackId
                ) {
                    dto = advanced
                } else {
                    dto = try await LaxifyAPI.shared.waveStart(settings: settings)
                }
            } else {
                dto = try await LaxifyAPI.shared.waveStart(settings: settings)
            }

            let songs = dto.tracks.map(\.song)
            guard !songs.isEmpty else { throw MusicServiceError.notFound }
            return WaveBatch(songs: songs, batchId: dto.sessionId)
        } catch let error as APIError {
            if case .notAuthenticated = error {
                throw MusicServiceError.missingAccessKey
            }
            throw MusicServiceError.underlying(error)
        }
    }

    /// Kept for the call sites that warm the wave before showing it; the
    /// session is opened lazily by `waveBatch`.
    func startWaveSession() async {}

    func reportWaveTrackStarted(trackId: String, batchId: String) async {
        try? await LaxifyAPI.shared.waveFeedback(
            sessionId: batchId, type: "trackStarted", trackId: trackId
        )
    }

    func reportWaveTrackFinished(
        trackId: String, batchId: String, playedSeconds: Double, durationSeconds: Double = 0
    ) async {
        try? await LaxifyAPI.shared.waveFeedback(
            sessionId: batchId, type: "trackFinished", trackId: trackId,
            playedSeconds: playedSeconds, durationSeconds: durationSeconds
        )
    }

    func reportWaveTrackSkipped(trackId: String, batchId: String, playedSeconds: Double) async {
        try? await LaxifyAPI.shared.waveFeedback(
            sessionId: batchId, type: "skip", trackId: trackId, playedSeconds: playedSeconds
        )
    }

    /// Settings are stored on the device and, if a session is running, pushed
    /// to it so the tail reshapes without a gap. The caller then refetches the
    /// tail through the normal `/wave/next` path.
    func applyWaveSettings(_ settings: WaveSettings, sessionId: String? = nil) async throws {
        settings.save()
        guard let sessionId else { return }
        _ = try? await LaxifyAPI.shared.waveApplySettings(sessionId: sessionId, settings: settings)
    }
}
