import Foundation

/// Caches the home feed between launches.
///
/// The screen used to sit on a spinner while the first network round trip
/// completed, every single time. Rendering the last feed immediately and
/// refreshing behind it makes the app feel instant, and it still shows
/// something useful when the network is unavailable.
enum HomeCache {
    private static let tracksKey = "laxify.home.tracks"
    private static let waveKey = "laxify.home.wave"
    private static let savedAtKey = "laxify.home.savedAt"

    /// Beyond this the cached feed is stale enough that showing it would be
    /// misleading rather than helpful.
    private static let maxAge: TimeInterval = 60 * 60 * 24 * 3

    private struct Entry: Codable {
        let id: String
        let title: String
        let artistId: String
        let artistName: String
        let albumTitle: String?
        let coverURL: String?
        let duration: TimeInterval
    }

    private static func encode(_ songs: [Song]) -> Data? {
        let entries = songs.map { song in
            Entry(
                id: song.id,
                title: song.title,
                artistId: song.artistId ?? "",
                artistName: song.artistName,
                albumTitle: song.albumTitle,
                coverURL: song.coverURL?.absoluteString,
                duration: song.duration
            )
        }
        return try? JSONEncoder().encode(entries)
    }

    private static func decode(_ data: Data) -> [Song] {
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
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

    private static var isFresh: Bool {
        let savedAt = UserDefaults.standard.double(forKey: savedAtKey)
        guard savedAt > 0 else { return false }
        return Date().timeIntervalSince1970 - savedAt < maxAge
    }

    static func loadRecommended() -> [Song] {
        guard isFresh, let data = UserDefaults.standard.data(forKey: tracksKey) else { return [] }
        return decode(data)
    }

    static func loadWave() -> [Song] {
        guard isFresh, let data = UserDefaults.standard.data(forKey: waveKey) else { return [] }
        return decode(data)
    }

    static func save(recommended: [Song], wave: [Song]) {
        if let data = encode(Array(recommended.prefix(40))) {
            UserDefaults.standard.set(data, forKey: tracksKey)
        }
        if let data = encode(Array(wave.prefix(40))) {
            UserDefaults.standard.set(data, forKey: waveKey)
        }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: savedAtKey)
    }
}
