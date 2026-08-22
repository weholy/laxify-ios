import Foundation

/// Remembers the artwork shown behind the sign-in screen.
///
/// Without this every launch starts on gradient placeholders and only swaps to
/// real covers once the network answers, which reads as the screen loading
/// twice. Caching the last set means the wall is real artwork from the first
/// frame, and the fresh fetch quietly replaces it.
enum CoverArtCache {
    private static let key = "laxify.signin.covers"
    private static let maxItems = 24

    private struct Entry: Codable {
        let id: String
        let title: String
        let artistName: String
        let coverURL: String
        let duration: TimeInterval
    }

    static func load() -> [Song] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            return []
        }

        return entries.compactMap { entry in
            guard let url = URL(string: entry.coverURL) else { return nil }
            return Song(
                id: entry.id,
                title: entry.title,
                artistName: entry.artistName,
                artistId: nil,
                albumTitle: nil,
                coverURL: url,
                duration: entry.duration
            )
        }
    }

    static func save(_ songs: [Song]) {
        let entries = songs.prefix(maxItems).compactMap { song -> Entry? in
            guard let cover = song.coverURL?.absoluteString else { return nil }
            return Entry(
                id: song.id,
                title: song.title,
                artistName: song.artistName,
                coverURL: cover,
                duration: song.duration
            )
        }

        guard let data = try? JSONEncoder().encode(Array(entries)) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
