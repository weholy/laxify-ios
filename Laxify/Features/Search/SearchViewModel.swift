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
    private(set) var categoryCovers: [String: URL] = [:]
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

        await loadCategoryCovers()
    }

    /// A banner cover per category, fetched in parallel. Best-effort — a
    /// category with no cover falls back to its gradient tile. Anything seen
    /// before is on disk, so it paints instantly on the next visit.
    private func loadCategoryCovers() async {
        let seeded = CategoryCoverCache.shared.seeded(keys: categories.map(\.id))
        for (id, url) in seeded where categoryCovers[id] == nil {
            categoryCovers[id] = url
        }

        let pending = categories.filter { categoryCovers[$0.id] == nil }
        guard !pending.isEmpty else { return }

        let found: [(String, URL)] = await withTaskGroup(of: (String, URL?).self) { group in
            for category in pending {
                group.addTask { [service] in
                    (category.id, await service.categoryCoverURL(id: category.id))
                }
            }
            var collected: [(String, URL)] = []
            for await (id, url) in group {
                if let url { collected.append((id, url)) }
            }
            return collected
        }

        for (id, url) in found {
            categoryCovers[id] = url
            CategoryCoverCache.shared.remember(key: id, url: url)
        }
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
