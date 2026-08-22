import Foundation

enum MusicServiceError: Error {
    case missingAccessKey
    case notFound
    case regionBlocked
    case underlying(Error)
}

extension Error {
    /// True when the source refused on geography grounds (HTTP 451), which in
    /// practice means the request left through a VPN exit it does not serve.
    var isRegionBlocked: Bool {
        if case MusicServiceError.regionBlocked = self { return true }
        return "\(self)".contains("451")
    }
}

protocol MusicService: Sendable {
    func homeContent() async throws -> HomeContent
    func search(query: String) async throws -> SearchResults
    func artistDetail(artistId: String) async throws -> ArtistDetail
    func streamURL(for songId: String) async throws -> URL
    func playlistTracks(collectionId: String) async throws -> (title: String, songs: [Song])
    func song(id: String) async throws -> Song
    func albumDetail(albumId: String) async throws -> (album: MusicAlbum, songs: [Song])
    func artistTracks(artistId: String, page: Int) async throws -> [Song]
}
