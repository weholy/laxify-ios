import Foundation

@MainActor
@Observable
final class SearchViewModel {
    // Results for a submitted query.
    private(set) var results: SearchResults?
    private(set) var isSearching = false
    private(set) var hasError = false

    // The browse surface shown before anyone searches.
    private(set) var popular: [Song] = []
    private(set) var categories: [MusicCategory] = []
    private(set) var isLoadingBrowse = false

    // Live completions for the half-typed field.
    private(set) var suggestions: [String] = []
    private var suggestTask: Task<Void, Never>?

    private let service: any MusicService

    init(service: any MusicService = CatalogService.shared) {
        self.service = service
    }

    /// Popular tracks and categories, loaded once per screen.
    func loadBrowseIfNeeded() async {
        guard popular.isEmpty, categories.isEmpty, !isLoadingBrowse else { return }
        isLoadingBrowse = true
        defer { isLoadingBrowse = false }

        async let popularResult = service.popularTracks()
        async let categoriesResult = service.categories()

        popular = (try? await popularResult) ?? []
        categories = (try? await categoriesResult) ?? []
        AsyncCoverImage.prefetchCovers(for: popular, width: 150)
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
        suggestions = []
        do {
            results = try await service.search(query: trimmed)
        } catch {
            results = nil
            hasError = true
        }
        isSearching = false
    }

    /// Debounced completions while typing. Cleared as soon as the field is.
    func updateSuggestions(for query: String) {
        suggestTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            suggestions = []
            return
        }

        suggestTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled, let self else { return }
            let fresh = (try? await self.service.suggestions(for: trimmed)) ?? []
            guard !Task.isCancelled else { return }
            self.suggestions = fresh
        }
    }

    func clearResults() {
        results = nil
        hasError = false
        suggestions = []
        suggestTask?.cancel()
    }
}
