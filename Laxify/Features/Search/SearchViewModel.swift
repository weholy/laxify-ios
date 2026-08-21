import Foundation

@MainActor
@Observable
final class SearchViewModel {
    private(set) var results: SearchResults?
    private(set) var isSearching = false

    private let service: any MusicService

    init(service: any MusicService = YandexMusicService.shared) {
        self.service = service
    }

    func search(query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = nil
            return
        }
        isSearching = true
        results = try? await service.search(query: trimmed)
        isSearching = false
    }
}
