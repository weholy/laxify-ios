import Foundation

struct MusicArtist: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let imageURL: URL?
    let bio: String?
    let trackCount: Int?
    let albumCount: Int?
}
