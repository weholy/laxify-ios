import Foundation

@MainActor
@Observable
final class ArtistViewModel {
    private(set) var detail: ArtistDetail?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private let artistId: String
    private let service: any MusicService

    init(artistId: String, service: any MusicService = YandexMusicService.shared) {
        self.artistId = artistId
        self.service = service
    }

    func loadIfNeeded() async {
        guard detail == nil, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        do {
            detail = try await service.artistDetail(artistId: artistId)
        } catch {
            errorMessage = "Не удалось загрузить артиста"
        }
        isLoading = false
    }
}
