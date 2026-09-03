import Foundation

@MainActor
@Observable
final class SearchViewModel {
    // Results for a submitted query.
    private(set) var results: SearchResults?
    private(set) var isSearching = false
    private(set) var hasError = false

    // The browse surface shown before anyone searches. Seeded from disk so
    // the screen has something on its first frame instead of a spinner.
    private(set) var popular: [Song] = BrowseCache.loadPopular()
    private(set) var categories: [MusicCategory] = BrowseCache.loadCategories()
    private(set) var categoryCovers: [String: URL] = [:]
    private(set) var isLoadingBrowse = false

    // Live completions for the half-typed field.
    private(set) var suggestions: [String] = []
    private var suggestTask: Task<Void, Never>?

    private let service: any MusicService

    init(service: any MusicService = CatalogService.shared) {
        self.service = service
    }

    /// Popular tracks and categories.
    ///
    /// Runs even when the cache already filled the screen — it just refreshes
    /// behind what is already drawn instead of replacing it with a spinner.
    func loadBrowseIfNeeded() async {
        guard !isLoadingBrowse else { return }
        isLoadingBrowse = true
        defer { isLoadingBrowse = false }

        async let popularResult = service.popularTracks()
        async let categoriesResult = service.categories()

        let freshPopular = (try? await popularResult) ?? []
        let freshCategories = (try? await categoriesResult) ?? []

        // Nothing came back: keep whatever the cache gave us rather than
        // blanking a screen that was already useful.
        if !freshPopular.isEmpty { popular = freshPopular }
        if !freshCategories.isEmpty { categories = freshCategories }

        if !freshPopular.isEmpty || !freshCategories.isEmpty {
            BrowseCache.save(popular: popular, categories: categories)
        }

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

    /// Answers already given, so going back to a query is instant.
    ///
    /// Small and in memory only: a search result is worth keeping for the
    /// length of a session — people try a word, back out, and try it again —
    /// and worth nothing after that.
    private var cache: [String: SearchResults] = [:]
    private var searchOrder: [String] = []
    private var searchTask: Task<Void, Never>?

    func search(query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchTask?.cancel()
            results = nil
            hasError = false
            isSearching = false
            return
        }

        let key = trimmed.lowercased()

        // A repeat costs nothing and shows nothing in between.
        if let cached = cache[key] {
            searchTask?.cancel()
            results = cached
            hasError = false
            isSearching = false
            suggestions = []
            return
        }

        // One search at a time. Without this a slow answer for an earlier
        // word could land after a fast one for the current word and replace
        // it — which is how "ничего не найдено" appeared over a query that
        // had results.
        searchTask?.cancel()
        isSearching = true
        hasError = false
        suggestions = []

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let fresh = try await self.service.search(query: trimmed)
                guard !Task.isCancelled else { return }
                self.remember(fresh, for: key)
                self.results = fresh
                self.hasError = false
            } catch is CancellationError {
                // Superseded, not failed. Saying nothing is correct.
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.results = nil
                self.hasError = true
            }
            self.isSearching = false
        }

        searchTask = task
        await task.value
    }

    private func remember(_ found: SearchResults, for key: String) {
        cache[key] = found
        searchOrder.append(key)
        // Twenty queries is more than a session uses and far less than a
        // memory problem.
        while searchOrder.count > 20, let oldest = searchOrder.first {
            searchOrder.removeFirst()
            if !searchOrder.contains(oldest) { cache[oldest] = nil }
        }
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
