import Foundation

/// One credited artist on a track.
struct SongArtist: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

struct Song: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    /// Every credited artist, in order. A track can list several, and each one
    /// should be reachable from the player — a joined string cannot express
    /// which part of the text belongs to whom.
    let artists: [SongArtist]
    let albumTitle: String?
    let coverURL: URL?
    let duration: TimeInterval
    /// False for a Spotify track with no SoundCloud stream behind it — shown
    /// greyed, can't be played or saved.
    var playable: Bool = true
    /// The title exactly as the source has it, before `TrackTitle.clean`
    /// tidies it for display. Nil wherever a song is built from something
    /// that never carried the untouched string (a backend DTO, a cached
    /// favourite). The one place this exists to serve: naming an exported
    /// file after what the uploader actually called it, not our cleaned-up
    /// version of it.
    var rawTitle: String?

    var artistName: String {
        artists.map(\.name).joined(separator: ", ")
    }

    var artistId: String? {
        artists.first?.id
    }

    init(
        id: String,
        title: String,
        artists: [SongArtist],
        albumTitle: String? = nil,
        coverURL: URL? = nil,
        duration: TimeInterval = 0,
        playable: Bool = true,
        rawTitle: String? = nil
    ) {
        self.id = id
        self.title = title
        self.artists = artists
        self.albumTitle = albumTitle
        self.coverURL = coverURL
        self.duration = duration
        self.playable = playable
        self.rawTitle = rawTitle
    }

    /// Convenience for the places that only ever had a name and an optional id
    /// — cached rows, backend payloads, local favourites.
    init(
        id: String,
        title: String,
        artistName: String,
        artistId: String?,
        albumTitle: String?,
        coverURL: URL?,
        duration: TimeInterval,
        playable: Bool = true,
        rawTitle: String? = nil
    ) {
        self.id = id
        self.title = title
        self.artists = artistName.isEmpty
            ? []
            : [SongArtist(id: artistId ?? "", name: artistName)]
        self.albumTitle = albumTitle
        self.coverURL = coverURL
        self.duration = duration
        self.playable = playable
        self.rawTitle = rawTitle
    }
}
