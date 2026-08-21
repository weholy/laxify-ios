import Foundation

@MainActor
@Observable
final class HomeViewModel {
    private(set) var content: HomeContent?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private(set) var waveTracks: [Song] = []
    private(set) var isLoadingWave = false
    private var waveSeed: [String] = []

    private let service: any MusicService

    init(service: any MusicService = YandexMusicService.shared) {
        self.service = service
    }

    func loadIfNeeded() async {
        guard content == nil, !isLoading else { return }
        await load()
    }

    func reload() async {
        await load()
    }

    /// Rebuilds the personalised feed whenever the set of favourite artists
    /// changes, so "your wave" reflects new likes instead of staying frozen
    /// on whatever was fetched at launch.
    func refreshWave(seedArtistIds: [String]) async {
        let seed = Array(seedArtistIds.sorted().prefix(6))
        guard seed != waveSeed else { return }
        waveSeed = seed

        guard !seed.isEmpty else {
            waveTracks = []
            return
        }

        isLoadingWave = true
        waveTracks = (try? await service.waveTracks(seedArtistIds: seed)) ?? []
        isLoadingWave = false
    }


    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            content = try await service.homeContent()
        } catch MusicServiceError.missingAccessKey {
            errorMessage = "Добавьте ключ доступа в Профиле"
        } catch MusicServiceError.notFound {
            errorMessage = "Библиотека пока недоступна в вашем регионе"
        } catch {
            errorMessage = "Не удалось загрузить главную (\(error))"
        }
        isLoading = false
    }
}
