import Foundation

/// Caches the search screen's browse surface between launches.
///
/// The same reasoning as `HomeCache`: opening search and watching a spinner
/// decide what to show is the wrong first impression for a screen whose whole
/// job is to answer quickly. The last set of popular tracks and categories
/// paints on the first frame and is replaced quietly when fresher ones land.
enum BrowseCache {
    // Per source, for the reason set out in `HomeCache`.
    private static var suffix: String {
        SelectedSource.current == .soundcloud ? "" : ".\(SelectedSource.current.rawValue)"
    }

    private static var popularKey: String { "laxify.browse.popular\(suffix)" }
    private static var categoriesKey: String { "laxify.browse.categories\(suffix)" }
    private static var savedAtKey: String { "laxify.browse.savedAt\(suffix)" }

    /// Popular picks and a category list move slowly; three days old is still
    /// a better answer than an empty screen.
    private static let maxAge: TimeInterval = 60 * 60 * 24 * 3

    private struct TrackEntry: Codable {
        let id: String
        let title: String
        let artistId: String
        let artistName: String
        let albumTitle: String?
        let coverURL: String?
        let duration: TimeInterval
    }

    private struct CategoryEntry: Codable {
        let id: String
        let title: String
    }

    private static var isFresh: Bool {
        let savedAt = UserDefaults.standard.double(forKey: savedAtKey)
        guard savedAt > 0 else { return false }
        return Date().timeIntervalSince1970 - savedAt < maxAge
    }

    static func loadPopular() -> [Song] {
        guard isFresh, let data = UserDefaults.standard.data(forKey: popularKey),
              let entries = try? JSONDecoder().decode([TrackEntry].self, from: data)
        else { return [] }

        return entries.map { entry in
            Song(
                id: entry.id,
                title: entry.title,
                artistName: entry.artistName,
                artistId: entry.artistId.isEmpty ? nil : entry.artistId,
                albumTitle: entry.albumTitle,
                coverURL: entry.coverURL.flatMap(URL.init(string:)),
                duration: entry.duration
            )
        }
    }

    static func loadCategories() -> [MusicCategory] {
        guard isFresh, let data = UserDefaults.standard.data(forKey: categoriesKey),
              let entries = try? JSONDecoder().decode([CategoryEntry].self, from: data)
        else { return [] }

        return entries.map { MusicCategory(id: $0.id, title: $0.title) }
    }

    static func save(popular: [Song], categories: [MusicCategory]) {
        let tracks = popular.prefix(30).map { song in
            TrackEntry(
                id: song.id,
                title: song.title,
                artistId: song.artistId ?? "",
                artistName: song.artistName,
                albumTitle: song.albumTitle,
                coverURL: song.coverURL?.absoluteString,
                duration: song.duration
            )
        }
        if let data = try? JSONEncoder().encode(Array(tracks)) {
            UserDefaults.standard.set(data, forKey: popularKey)
        }

        let list = categories.map { CategoryEntry(id: $0.id, title: $0.title) }
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: categoriesKey)
        }

        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: savedAtKey)
    }
}
