import Foundation

/// The state behind the "Моя волна" tab.
///
/// The station itself is the source's own — the same `waveBatch` the home
/// screen used — so this is mostly about keeping a comfortable buffer of
/// upcoming tracks and resolving an artist photo for the backdrop.
@MainActor
@Observable
final class MyWaveViewModel {
    private(set) var tracks: [Song] = HomeCache.loadWave()
    private(set) var batchId: String?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    /// URL the backdrop is drawn from — the artist's photo when there is one,
    /// the current cover until then.
    private(set) var backdropURL: URL?
    /// True once the URL above is a real artist photo rather than a cover, so
    /// the screen can show it sharp rather than heavily blurred.
    private(set) var backdropIsArtistPhoto = false
    private var backdropArtistId: String?

    var settings: WaveSettings = .load()

    private var loadedAt: Date?
    private static let freshness: TimeInterval = 15 * 60

    private let service: any MusicService

    init(service: any MusicService = CatalogService.shared) {
        self.service = service
    }

    func loadIfNeeded() async {
        if let loadedAt, Date().timeIntervalSince(loadedAt) < Self.freshness, !tracks.isEmpty {
            return
        }
        await load()
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        do {
            let batch = try await CatalogService.shared.waveBatch()
            tracks = batch.songs
            batchId = batch.batchId
            loadedAt = Date()
            HomeCache.save(recommended: HomeCache.loadRecommended(), wave: batch.songs)
            AsyncCoverImage.prefetchCovers(for: Array(batch.songs.prefix(12)), width: 220)
        } catch {
            if tracks.isEmpty { errorMessage = "Волна пока недоступна" }
        }
        isLoading = false
    }

    /// Pulls the next run so the deck never visibly empties.
    func extend() async {
        guard !isLoading, let last = tracks.last else { return }
        isLoading = true
        if let batch = try? await CatalogService.shared.waveBatch(
            sessionId: batchId, lastTrackId: last.id
        ) {
            let existing = Set(tracks.map(\.id))
            tracks.append(contentsOf: batch.songs.filter { !existing.contains($0.id) })
            batchId = batch.batchId
        }
        isLoading = false
    }

    func apply(_ newSettings: WaveSettings) async {
        settings = newSettings
        newSettings.save()
        try? await CatalogService.shared.applyWaveSettings(newSettings, sessionId: batchId)

        // Playing: keep the current track, reshape only what comes after it —
        // the way Yandex's wave settings take effect without a gap. Idle:
        // rebuild the preview outright.
        if AudioPlayerController.shared.isPlayingWave {
            AudioPlayerController.shared.reshapeWaveTail()
        } else {
            loadedAt = nil
            await load()
        }
    }

    /// Resolves the backdrop for whatever is in focus. The cover shows at
    /// once; the artist photo replaces it if the catalogue has one.
    func updateBackdrop(for song: Song?) async {
        guard let song else { return }
        let artistId = song.artistId ?? ""
        guard artistId != backdropArtistId else { return }
        backdropArtistId = artistId
        backdropURL = song.coverURL
        backdropIsArtistPhoto = false

        guard !artistId.isEmpty else { return }
        if let photo = try? await service.artistDetail(artistId: artistId).artist.imageURL,
           backdropArtistId == artistId {
            backdropURL = photo
            backdropIsArtistPhoto = true
        }
    }
}
