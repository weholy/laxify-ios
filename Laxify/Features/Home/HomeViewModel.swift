import Foundation

@Observable
final class HomeViewModel {
    private(set) var content: HomeContent?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

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

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            content = try await service.homeContent()
        } catch MusicServiceError.missingAccessKey {
            errorMessage = "Добавьте ключ доступа в Профиле"
        } catch {
            errorMessage = "Не удалось загрузить главную"
        }
        isLoading = false
    }
}
