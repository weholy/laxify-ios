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

    private let service: any MusicService

    init(service: any MusicService = YandexMusicService.shared) {
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
        // Refresh even when cached content is on screen — it is a starting
        // point, not a reason to skip loading.
        await load()
    }

    func reload() async {
        await load()
    }

    /// Loads the personal radio station.
    ///
    /// This is the source's own station engine, which selects by genre, mood
    /// and tempo rather than just by artist, and adapts to the skip/finish
    /// feedback the player reports back.
    func loadWave(force: Bool = false) async {
        guard !isLoadingWave else { return }

        isLoadingWave = true
        waveError = nil

        await YandexMusicService.shared.startWaveSession()

        do {
            let batch = try await YandexMusicService.shared.waveBatch()
            waveTracks = batch.songs
            waveBatchId = batch.batchId
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
        if let batch = try? await YandexMusicService.shared.waveBatch(lastTrackId: last.id) {
            let existing = Set(waveTracks.map(\.id))
            waveTracks.append(contentsOf: batch.songs.filter { !existing.contains($0.id) })
            waveBatchId = batch.batchId
        }
        isLoadingWave = false
    }

    func applyWaveSettings(_ settings: WaveSettings) async {
        waveSettings = settings
        settings.save()
        try? await YandexMusicService.shared.applyWaveSettings(settings)
        await loadWave(force: true)
    }


    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let fresh = try await service.homeContent()
            content = fresh
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
