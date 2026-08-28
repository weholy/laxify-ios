import Foundation

enum SearchBestMatch: String, Sendable {
    case track
    case artist
    case album
    case other
}

struct SearchResults: Sendable {
    var tracks: [Song] = []
    var artists: [MusicArtist] = []
    var albums: [MusicAlbum] = []
    var correctedQuery: String?
    var bestMatch: SearchBestMatch = .other

    var isEmpty: Bool { tracks.isEmpty && artists.isEmpty && albums.isEmpty }
}

struct HomeContent: Sendable {
    var collections: [MusicCollection] = []
    var recommendedTracks: [Song] = []
}

/// A browsable genre on the search screen. `id` is the source's genre key,
/// `title` is what to show on the banner.
struct MusicCategory: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
}

struct ArtistDetail: Sendable {
    var artist: MusicArtist
    var topTracks: [Song] = []
    var releases: [MusicAlbum] = []
    var similarArtists: [MusicArtist] = []
}
