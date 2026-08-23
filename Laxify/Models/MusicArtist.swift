import Foundation

struct MusicArtist: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let imageURL: URL?
    let bio: String?
    let trackCount: Int?
    let albumCount: Int?
    /// Whether the source vouches for this account being who it says it is.
    /// Absent for a great many genuine artists, so its absence is not a
    /// judgement — but its presence is conclusive.
    var isVerified: Bool = false
    var followers: Int?
}
