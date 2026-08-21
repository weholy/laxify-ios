import Foundation

enum MusicServiceError: Error {
    case missingAccessKey
    case notFound
    case underlying(Error)
}

protocol MusicService: Sendable {
    func homeContent() async throws -> HomeContent
    func search(query: String) async throws -> SearchResults
    func artistDetail(artistId: String) async throws -> ArtistDetail
    func streamURL(for songId: String) async throws -> URL
}
