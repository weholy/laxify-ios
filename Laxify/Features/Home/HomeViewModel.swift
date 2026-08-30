import Foundation

@MainActor
@Observable
final class HomeViewModel {
    private(set) var content: HomeContent?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private(set) var waveTracks: [Song] = HomeCache.loadWave()
    private(set) var isLoadingWave = false
    private(set) var waveError: String?
    private(set) var waveBatchId: String?
    var waveSettings: WaveSettings = .load()

    private(set) var isLoadingMore = false
    private var recommendationPage = 0
    private var exhaustedRecommendations = false

    private let service: any MusicService

    /// When the feed last came from the network.
    ///
    /// The view's `.task` runs again every time Home reappears — switching
    /// tabs, closing the player, coming back from an artist. Reloading on
    /// each of those replaced the tracks under the listener's finger, which
    /// is why the feed seemed to shuffle itself.
    private var loadedAt: Date?
    private var waveLoadedAt: Date?

    /// Long enough that returning to Home shows what was there, short enough
    /// that the feed is not yesterday's when the app is left open.
    private static let freshness: TimeInterval = 15 * 60

    init(service: any MusicService = CatalogService.shared) {
        self.service = service

        // Render last session's feed immediately; the network refresh below
        // replaces it once it arrives, so the screen is never a bare spinner.
        let cached = HomeCache.loadRecommended()
        if !cached.isEmpty {
            content = HomeContent(collections: [], recommendedTracks: cached)
        }
    }

    func loadIfNeeded() async {
        guard !isLoading else { return }

        if let loadedAt, Date().timeIntervalSince(loadedAt) < Self.freshness, content != nil {
            return
        }

        await load()
    }

    /// Pull to refresh, which is the one case where replacing what is on
    /// screen is exactly what was asked for.
    func reload() async {
        loadedAt = nil
        waveLoadedAt = nil
        await load()
        await loadWave(force: true)
    }

    /// Loads the personal radio station.
    ///
    /// This is the source's own station engine, which selects by genre, mood
    /// and tempo rather than just by artist, and adapts to the skip/finish
    /// feedback the player reports back.
    func loadWave(force: Bool = false) async {
        guard !isLoadingWave else { return }

        if !force,
           let waveLoadedAt,
           Date().timeIntervalSince(waveLoadedAt) < Self.freshness,
           !waveTracks.isEmpty {
            return
        }

        isLoadingWave = true
        waveError = nil

        await CatalogService.shared.startWaveSession()

        do {
            let batch = try await CatalogService.shared.waveBatch()
            waveTracks = batch.songs
            waveBatchId = batch.batchId
            waveLoadedAt = Date()
            AsyncCoverImage.prefetchCovers(for: batch.songs, width: 150)
            HomeCache.save(
                recommended: content?.recommendedTracks ?? [],
                wave: batch.songs
            )
        } catch {
            if waveTracks.isEmpty {
                waveError = "Волна пока недоступна"
            }
        }

        isLoadingWave = false
    }

    /// Pulls the next run so the station never visibly runs dry.
    func extendWave() async {
        guard !isLoadingWave, let last = waveTracks.last else { return }
        isLoadingWave = true
        if let batch = try? await CatalogService.shared.waveBatch(
            sessionId: waveBatchId, lastTrackId: last.id
        ) {
            let existing = Set(waveTracks.map(\.id))
            waveTracks.append(contentsOf: batch.songs.filter { !existing.contains($0.id) })
            waveBatchId = batch.batchId
        }
        isLoadingWave = false
    }

    /// Appends another run of recommendations.
    ///
    /// The source has no "recommendations page 2", so this widens the net
    /// instead: each call pulls a different term, which keeps the feed
    /// growing without repeating what is already on screen.
    func extendRecommendations() async {
        guard !isLoadingMore, !exhaustedRecommendations else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        let terms = Self.discoveryTerms.shuffled().prefix(2)
        var existing = Set((content?.recommendedTracks ?? []).map(\.id))
        var added: [Song] = []

        for term in terms {
            guard let results = try? await service.search(query: term) else { continue }
            for song in results.tracks where !existing.contains(song.id) {
                existing.insert(song.id)
                added.append(song)
            }
        }

        guard !added.isEmpty else {
            // Nothing new came back twice in a row; stop asking rather than
            // hammering the source on every scroll.
            recommendationPage += 1
            exhaustedRecommendations = recommendationPage > 6
            return
        }

        recommendationPage += 1
        content = HomeContent(
            collections: content?.collections ?? [],
            recommendedTracks: (content?.recommendedTracks ?? []) + added.shuffled()
        )
    }

    private static let discoveryTerms = [
        "хиты", "новинки", "русский рэп", "поп музыка", "рок", "инди",
        "электронная музыка", "хип-хоп", "лирика", "танцевальная",
        "Travis Scott", "Drake", "The Weeknd", "Kendrick Lamar",
        "Playboi Carti", "Tyler The Creator", "джаз", "чилл"
    ]

    func applyWaveSettings(_ settings: WaveSettings) async {
        waveSettings = settings
        settings.save()
        try? await CatalogService.shared.applyWaveSettings(settings, sessionId: waveBatchId)
        await loadWave(force: true)
    }


    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let fresh = try await service.homeContent()
            content = fresh
            // Only counted as loaded when it actually finished. A load
            // cancelled by navigating away used to mark the feed fresh, so
            // coming back showed nothing and did not try again.
            loadedAt = Task.isCancelled ? nil : Date()

            // Artwork starts loading now, while the rows are still being
            // laid out, rather than when each one scrolls into view.
            AsyncCoverImage.prefetchCovers(for: fresh.recommendedTracks, width: 150)
            AsyncCoverImage.prefetchCovers(for: waveTracks, width: 150)
            HomeCache.save(recommended: fresh.recommendedTracks, wave: waveTracks)
        } catch MusicServiceError.missingAccessKey {
            errorMessage = "Добавьте ключ доступа в Профиле"
        } catch MusicServiceError.notFound {
            if content == nil {
                errorMessage = "Похоже, сеть блокирует доступ к музыке. Если включён VPN, попробуйте отключить его или пропустить музыку мимо туннеля"
            }
        } catch {
            if content == nil {
                errorMessage = "Не удалось загрузить главную"
            }
        }
        isLoading = false
    }
}
