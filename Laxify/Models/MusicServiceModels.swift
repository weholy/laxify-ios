import Foundation

struct SearchResults: Sendable {
    var tracks: [Song] = []
    var artists: [MusicArtist] = []
    var albums: [MusicAlbum] = []
    var correctedQuery: String?

    var isEmpty: Bool { tracks.isEmpty && artists.isEmpty && albums.isEmpty }
}

struct HomeContent: Sendable {
    var collections: [MusicCollection] = []
    var recommendedTracks: [Song] = []
}

struct ArtistDetail: Sendable {
    var artist: MusicArtist
    var topTracks: [Song] = []
    var releases: [MusicAlbum] = []
    var similarArtists: [MusicArtist] = []
}
