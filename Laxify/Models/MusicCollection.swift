import Foundation

struct MusicCollection: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String?
    let coverURL: URL?
}
