import Foundation

/// The wave, served by the backend.
///
/// A station is picked from what the listener actually played and liked, and
/// selects on how a track sounds rather than on who made it — which is the
/// difference between a wave and a shuffle of artists already in the library.
///
/// The signatures here match what the screens already call, so switching the
/// source underneath did not ripple into them.
extension CatalogService {
    /// Fetches the next run.
    ///
    /// `lastTrackId` matters: passing the track that just finished continues
    /// the same run from there, instead of rebuilding the station and
    /// replaying what was already heard.
    func waveBatch(lastTrackId: String? = nil) async throws -> WaveBatch {
        let settings = WaveSettings.load()

        do {
            let response = try await LaxifyAPI.shared.wave(
                limit: 40,
                mood: settings.mood.rawValue,
                diversity: settings.diversity.rawValue,
                seed: lastTrackId
            )

            let songs = response.tracks.map(\.song)
            guard !songs.isEmpty else { throw MusicServiceError.notFound }

            // The server is stateless about runs, so the id is ours; the
            // player only uses it to tie feedback to the run it came from.
            return WaveBatch(songs: songs, batchId: UUID().uuidString)
        } catch let error as APIError {
            if case .notAuthenticated = error {
                throw MusicServiceError.missingAccessKey
            }
            throw MusicServiceError.underlying(error)
        }
    }

    /// Kept so the wave can be warmed before it is shown; the server keeps no
    /// session of its own.
    func startWaveSession() async {}

    /// The wave learns from ordinary listening events, which the player
    /// already reports for every track it plays — including the source it came
    /// from. Reporting again here would count each track twice and skew the
    /// very history the next run is built from.
    func reportWaveTrackStarted(trackId: String, batchId: String) async {}

    func reportWaveTrackFinished(trackId: String, batchId: String, playedSeconds: Double) async {}

    func reportWaveTrackSkipped(trackId: String, playedSeconds: Double) async {}

    /// Settings are stored on the device and sent with each request, so a
    /// change takes effect on the next run without a round trip of its own.
    func applyWaveSettings(_ settings: WaveSettings) async throws {
        settings.save()
    }
}
