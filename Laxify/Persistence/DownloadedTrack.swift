import Foundation
import SwiftData

/// A track kept on the device.
///
/// The audio itself is a file in Application Support named by track id; this
/// row is the index over those files — what each one is, how big it was, when
/// it was saved. Keeping the metadata here means the downloads list, and the
/// player's decision to use a local file, never wait on the network or on a
/// directory scan.
@Model
final class DownloadedTrack {
    @Attribute(.unique) var id: String
    var title: String
    var artistName: String
    var artistId: String?
    var albumTitle: String?
    var coverURLString: String?
    var duration: TimeInterval
    /// Bytes on disk, so the screen can say what the library costs.
    var byteCount: Int
    var savedAt: Date

    init(song: Song, byteCount: Int, savedAt: Date = .now) {
        self.id = song.id
        self.title = song.title
        self.artistName = song.artistName
        self.artistId = song.artistId
        self.albumTitle = song.albumTitle
        self.coverURLString = song.coverURL?.absoluteString
        self.duration = song.duration
        self.byteCount = byteCount
        self.savedAt = savedAt
    }

    var coverURL: URL? {
        coverURLString.flatMap(URL.init(string:))
    }

    var song: Song {
        Song(
            id: id,
            title: title,
            artistName: artistName,
            artistId: artistId,
            albumTitle: albumTitle,
            coverURL: coverURLString.flatMap(URL.init(string:)),
            duration: duration
        )
    }
}
