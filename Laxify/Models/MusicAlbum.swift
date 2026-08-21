import Foundation

struct MusicAlbum: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let artistName: String
    let coverURL: URL?
    let year: Int?
}
