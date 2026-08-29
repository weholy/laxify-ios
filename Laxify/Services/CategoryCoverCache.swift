import Foundation

/// Cover art for a text query (a wave mood, a search genre), cached to disk
/// so it is fetched once ever — not on every time the sheet opens. Without
/// this the wave-settings and search-browse tiles show their gradient
/// fallback for a beat every single time.
@MainActor
@Observable
final class CategoryCoverCache {
    static let shared = CategoryCoverCache()

    private(set) var byQuery: [String: URL] = [:]
    private var inFlight: Set<String> = []

    private static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("category-covers.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let stored = try? JSONDecoder().decode([String: String].self, from: data) {
            byQuery = stored.compactMapValues(URL.init(string:))
        }
    }

    /// Cached cover for a text query, or nil while it is being fetched.
    func cover(for query: String) -> URL? {
        resolve(key: query) { await CatalogService.shared.coverForQuery(query) }
    }

    /// Cached cover for something identified by an opaque key (e.g. a search
    /// category id), with a caller-supplied fetch.
    func cover(key: String, fetch: @escaping () async -> URL?) -> URL? {
        resolve(key: "k:" + key, fetch: fetch)
    }

    /// Warm several text queries at once — call on launch for the wave moods.
    func prefetch(_ queries: [String]) {
        for query in queries where byQuery[query] == nil {
            _ = cover(for: query)
        }
    }

    /// Store a cover a caller fetched its own way (search category banners).
    func remember(key: String, url: URL) {
        byQuery["k:" + key] = url
        persist()
    }

    /// The `key:` covers already on disk, un-prefixed — to seed a view model.
    func seeded(keys: [String]) -> [String: URL] {
        var out: [String: URL] = [:]
        for key in keys {
            if let url = byQuery["k:" + key] { out[key] = url }
        }
        return out
    }

    private func resolve(key: String, fetch: @escaping () async -> URL?) -> URL? {
        if let hit = byQuery[key] { return hit }
        guard !inFlight.contains(key) else { return nil }
        inFlight.insert(key)
        Task { [weak self] in
            defer { self?.inFlight.remove(key) }
            guard let url = await fetch() else { return }
            self?.byQuery[key] = url
            self?.persist()
        }
        return nil
    }

    private func persist() {
        let plain = byQuery.mapValues(\.absoluteString)
        if let data = try? JSONEncoder().encode(plain) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }
}
