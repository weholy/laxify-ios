import Foundation

@MainActor
@Observable
final class ArtistViewModel {
    private(set) var detail: ArtistDetail?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private let artistId: String
    private let service: any MusicService

    init(artistId: String, service: any MusicService = CatalogService.shared) {
        self.artistId = artistId
        self.service = service
    }

    func loadIfNeeded() async {
        guard detail == nil, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        do {
            let loaded = try await service.artistDetail(artistId: artistId)
            detail = loaded
            // Warms the cache before the rows scroll into view — the same
            // reason every other list does this. Artist and album screens
            // were the two places that didn't, which is what made covers
            // there noticeably slower to appear than everywhere else.
            AsyncCoverImage.prefetchCovers(for: loaded.topTracks, width: 56)
        } catch {
            errorMessage = "Не удалось загрузить артиста"
        }
        isLoading = false
    }
}
