import Foundation
import SwiftData

@Model
final class FavoriteTrack {
    @Attribute(.unique) var id: String
    var title: String
    var artistName: String
    var artistId: String?
    var albumTitle: String?
    var coverURLString: String?
    var duration: TimeInterval
    var addedAt: Date

    init(song: Song, addedAt: Date = .now) {
        self.id = song.id
        self.title = song.title
        self.artistName = song.artistName
        self.artistId = song.artistId
        self.albumTitle = song.albumTitle
        self.coverURLString = song.coverURL?.absoluteString
        self.duration = song.duration
        self.addedAt = addedAt
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
