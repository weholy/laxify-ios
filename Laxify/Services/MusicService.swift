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
        if let serviceError = self as? MusicServiceError, case .regionBlocked = serviceError {
            return true
        }
        // The package surfaces the upstream status inside its own error type,
        // so the code is only reachable through the description.
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
