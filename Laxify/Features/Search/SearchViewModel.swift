import Foundation

@MainActor
@Observable
final class SearchViewModel {
    private(set) var results: SearchResults?
    private(set) var isSearching = false
    private(set) var hasError = false

    private let service: any MusicService

    init(service: any MusicService = CatalogService.shared) {
        self.service = service
    }

    func search(query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = nil
            hasError = false
            return
        }
        isSearching = true
        hasError = false
        do {
            results = try await service.search(query: trimmed)
        } catch {
            results = nil
            hasError = true
        }
        isSearching = false
    }
}
