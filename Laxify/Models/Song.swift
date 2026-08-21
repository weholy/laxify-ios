import Foundation

struct Song: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let artistName: String
    let artistId: String?
    let albumTitle: String?
    let coverURL: URL?
    let duration: TimeInterval
}
