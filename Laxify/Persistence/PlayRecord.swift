import Foundation
import SwiftData

/// One track, played once, recorded on the device.
///
/// Statistics used to be computed entirely on the server, which means they
/// showed nothing whenever it could not be reached — and on some networks it
/// never can. The same plays are now kept here as well, so the figures are
/// always available and are simply better when the server can add what other
/// devices contributed.
@Model
final class PlayRecord {
    /// Which track, so the same one played twice is counted twice but
    /// recognised as one track.
    var trackId: String
    var title: String
    var artistName: String
    var artistId: String?
    var coverURL: String?
    var genre: String?

    var playedAt: Date
    /// How much was actually heard. A skip after three seconds must not count
    /// the same as a full listen.
    var secondsPlayed: Double
    var completed: Bool

    /// Whether the server has this one. Kept so a device that was offline can
    /// hand over what it collected without sending everything twice.
    var isSynced: Bool

    init(
        trackId: String,
        title: String,
        artistName: String,
        artistId: String? = nil,
        coverURL: String? = nil,
        genre: String? = nil,
        playedAt: Date = .now,
        secondsPlayed: Double,
        completed: Bool,
        isSynced: Bool = false
    ) {
        self.trackId = trackId
        self.title = title
        self.artistName = artistName
        self.artistId = artistId
        self.coverURL = coverURL
        self.genre = genre
        self.playedAt = playedAt
        self.secondsPlayed = secondsPlayed
        self.completed = completed
        self.isSynced = isSynced
    }
}
