import Foundation

struct SearchResults: Sendable {
    var tracks: [Song] = []
    var artists: [MusicArtist] = []
    var albums: [MusicAlbum] = []
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
