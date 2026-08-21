import Foundation

enum WaveRanking {
    static func reorder(_ tracks: [Song], favoriteArtistIds: Set<String>) -> [Song] {
        guard !favoriteArtistIds.isEmpty else { return tracks }

        let matching = tracks.filter { song in
            song.artistId.map(favoriteArtistIds.contains) ?? false
        }
        let rest = tracks.filter { song in
            !(song.artistId.map(favoriteArtistIds.contains) ?? false)
        }
        return matching + rest
    }
}
