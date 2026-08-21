import Foundation

@MainActor
@Observable
final class PlaylistDetailViewModel {
    private(set) var title: String
    private(set) var songs: [Song] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private let collectionId: String
    private let service: any MusicService

    init(collection: MusicCollection, service: any MusicService = YandexMusicService.shared) {
        self.title = collection.title
        self.collectionId = collection.id
        self.service = service
    }

    func loadIfNeeded() async {
        guard songs.isEmpty, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        do {
            let result = try await service.playlistTracks(collectionId: collectionId)
            title = result.title
            songs = result.songs
        } catch {
            errorMessage = "Не удалось загрузить треки"
        }
        isLoading = false
    }
}
