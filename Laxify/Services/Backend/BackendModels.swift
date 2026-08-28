import Foundation

struct BackendTokens: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
}

struct BackendSessionResponse: Codable, Sendable {
    let tokens: BackendTokens
    let isNewUser: Bool
    let needsOnboarding: Bool
    let needsLocalMigration: Bool
}

struct BackendUser: Codable, Sendable, Identifiable {
    let id: String
    let username: String
    let displayName: String
    let email: String
    let avatarUrl: String?
    let googleAvatarUrl: String?
    let bio: String?
    let isProfilePublic: Bool
    let isStatsPublic: Bool
    let hasCompletedOnboarding: Bool
    let isAdmin: Bool
    /// Whether the address has been confirmed, and whether a password
    /// exists — a Google account starts with neither.
    var emailVerified: Bool = false
    var hasPassword: Bool = false

    var avatarURL: URL? {
        if let avatarUrl, let url = URL(string: avatarUrl) { return url }
        if let googleAvatarUrl, let url = URL(string: googleAvatarUrl) { return url }
        return nil
    }
}

struct UsernameAvailability: Codable, Sendable {
    let username: String
    let available: Bool
    let reason: String?
    let suggestions: [String]
}

struct BackendTrack: Codable, Sendable {
    let trackId: String
    let title: String
    let artistName: String
    let artistId: String?
    let albumTitle: String?
    let albumId: String?
    let coverUrl: String?
    let durationSeconds: Double
    /// Sent so listening statistics can be grouped by genre. The app does not
    /// always know it, and the server keeps whatever it has been told once.
    var genre: String?

    /// Built from stored fields rather than from a Song, for records read
    /// back off the device.
    init(
        trackId: String,
        title: String,
        artistName: String,
        artistId: String?,
        albumTitle: String?,
        albumId: String?,
        coverUrl: String?,
        durationSeconds: Double,
        genre: String?
    ) {
        self.trackId = trackId
        self.title = title
        self.artistName = artistName
        self.artistId = artistId
        self.albumTitle = albumTitle
        self.albumId = albumId
        self.coverUrl = coverUrl
        self.durationSeconds = durationSeconds
        self.genre = genre
    }

    init(song: Song) {
        trackId = song.id
        title = song.title
        artistName = song.artistName
        artistId = song.artistId
        albumTitle = song.albumTitle
        albumId = nil
        coverUrl = song.coverURL?.absoluteString
        durationSeconds = song.duration
    }

    var song: Song {
        Song(
            id: trackId,
            title: title,
            artistName: artistName,
            artistId: artistId,
            albumTitle: albumTitle,
            coverURL: coverUrl.flatMap(URL.init(string:)),
            duration: durationSeconds
        )
    }
}

struct BackendFavorite: Codable, Sendable {
    let track: BackendTrack
    let addedAt: Date
}

// MARK: - Playlists

/// A user playlist as the server lists it. `id` is the server's UUID string.
struct PlaylistDTO: Codable, Sendable, Identifiable, Hashable {
    let id: String
    let title: String
    let description: String?
    let coverUrl: String?
    let isPublic: Bool
    let shareSlug: String
    let trackCount: Int
    let totalDurationSeconds: Double
    let updatedAt: Date

    var coverURL: URL? { coverUrl.flatMap(URL.init(string:)) }
}

struct PlaylistItemDTO: Codable, Sendable, Identifiable {
    let id: String
    let track: BackendTrack
    let position: Int

    var song: Song { track.song }
}

struct PlaylistDetailDTO: Codable, Sendable {
    let id: String
    let title: String
    let description: String?
    let coverUrl: String?
    let isPublic: Bool
    let shareSlug: String
    let trackCount: Int
    let totalDurationSeconds: Double
    let updatedAt: Date
    let items: [PlaylistItemDTO]
    let canEdit: Bool

    var songs: [Song] {
        items.sorted { $0.position < $1.position }.map(\.song)
    }

    var summary: PlaylistDTO {
        PlaylistDTO(
            id: id, title: title, description: description, coverUrl: coverUrl,
            isPublic: isPublic, shareSlug: shareSlug, trackCount: trackCount,
            totalDurationSeconds: totalDurationSeconds, updatedAt: updatedAt
        )
    }
}

struct BackendPage<Item: Codable & Sendable>: Codable, Sendable {
    let items: [Item]
    let total: Int
    let limit: Int
    let offset: Int
}

struct BackendStats: Codable, Sendable {
    let totalSeconds: Double
    let totalTracks: Int
    let currentStreakDays: Int
    let longestStreakDays: Int
}

struct PlaybackEvent: Codable, Sendable {
    let track: BackendTrack
    let playedAt: Date
    let secondsPlayed: Double
    let completed: Bool
    let source: String?
}

struct MessageResponse: Codable, Sendable {
    let detail: String
}

// MARK: - Catalogue

/// One track as the server describes it.
///
/// The server normalises whatever source it used into this single shape, so
/// the app never learns which one answered.
struct CatalogTrackDTO: Codable, Sendable {
    let id: String
    let title: String
    let artistId: String?
    let artistName: String
    let artworkUrl: String?
    let durationSeconds: Double
    let permalink: String?
    let genre: String?
    let playbackCount: Int?

    var song: Song {
        Song(
            id: id,
            title: title,
            artistName: artistName,
            artistId: artistId,
            albumTitle: nil,
            coverURL: artworkUrl.flatMap(URL.init(string:)),
            duration: durationSeconds
        )
    }
}

/// One browsable genre from `/discover/genres`.
struct DiscoverGenre: Codable, Sendable, Identifiable, Hashable {
    let id: String
    let title: String
}

struct CatalogArtistDTO: Codable, Sendable {
    let id: String
    let name: String
    let avatarUrl: String?
    let followers: Int?
    let description: String?
    let trackCount: Int?
    var isVerified: Bool = false

    var artist: MusicArtist {
        MusicArtist(
            id: id,
            name: name,
            imageURL: avatarUrl.flatMap(URL.init(string:)),
            bio: description,
            trackCount: trackCount,
            albumCount: nil,
            isVerified: isVerified,
            followers: followers
        )
    }
}

struct CatalogPlaylistDTO: Codable, Sendable {
    let id: String
    let title: String
    let artworkUrl: String?
    let trackCount: Int
    let ownerName: String?
    var year: Int?
    /// "album", "ep", "single", or nil for a plain playlist.
    var kind: String?

    var album: MusicAlbum {
        MusicAlbum(
            id: id,
            title: title,
            artistName: ownerName ?? "",
            coverURL: artworkUrl.flatMap(URL.init(string:)),
            year: year
        )
    }
}

struct ArtistDetailResponse: Codable, Sendable {
    let artist: CatalogArtistDTO
    let topTracks: [CatalogTrackDTO]
    let releases: [CatalogPlaylistDTO]
    let similarArtists: [CatalogArtistDTO]
}

struct CatalogSearchResponse: Codable, Sendable {
    let tracks: [CatalogTrackDTO]
    let artists: [CatalogArtistDTO]
    let playlists: [CatalogPlaylistDTO]
}

struct CatalogStreamResponse: Codable, Sendable {
    let url: String
}

struct WaveResponse: Codable, Sendable {
    let tracks: [CatalogTrackDTO]
    let seedTrackIds: [String]
    let isPersonalised: Bool
}

struct HomeFeedResponse: Codable, Sendable {
    let wave: [CatalogTrackDTO]
    let forYou: [CatalogTrackDTO]
    let charts: [CatalogTrackDTO]
}

struct EmailCodeResponse: Codable, Sendable {
    let sent: Bool
    let resendAfterSeconds: Int
    /// Present only while mail delivery is still being configured server-side.
    let debugCode: String?
}

struct EmailVerifiedResponse: Codable, Sendable {
    let verified: Bool
    let needsPassword: Bool
}

// MARK: - Listening statistics

struct ReplayPeriod: Codable, Sendable, Identifiable, Hashable {
    let id: String
    let title: String
    let shortTitle: String
    var isCurrent: Bool = false
}

struct ReplayArtist: Codable, Sendable, Identifiable, Hashable {
    let id: String?
    let name: String
    let artworkUrl: String?
    let minutes: Int
    let plays: Int

    var artworkURL: URL? { artworkUrl.flatMap(URL.init(string:)) }
}

struct ReplayTrack: Codable, Sendable, Identifiable, Hashable {
    let id: String
    let title: String
    let artistName: String
    let artworkUrl: String?
    let plays: Int
    let minutes: Int

    var artworkURL: URL? { artworkUrl.flatMap(URL.init(string:)) }
}

struct ReplayGenre: Codable, Sendable, Identifiable, Hashable {
    let name: String
    let plays: Int

    var id: String { name }
}

struct ReplaySummary: Codable, Sendable {
    let period: ReplayPeriod
    let totalMinutes: Int
    let totalPlays: Int
    let distinctTracks: Int
    let distinctArtists: Int
    let topArtists: [ReplayArtist]
    let topTracks: [ReplayTrack]
    let genres: [ReplayGenre]
    let activeDays: Int
    let longestStreakDays: Int

    var isEmpty: Bool { totalPlays == 0 }
}

// MARK: - Lyrics

struct LyricsResponse: Codable, Sendable {
    struct Line: Codable, Sendable {
        let timestamp: Double
        let text: String
    }

    let found: Bool
    let source: String?
    let synced: [Line]
    let plain: String?
}

struct ReplayBundle: Codable, Sendable {
    let periods: [ReplayPeriod]
    let current: ReplaySummary?
    let previous: ReplaySummary?
}

struct ShowcaseTrack: Codable, Sendable, Identifiable {
    let id: String
    let title: String
    let artistName: String
    let artworkUrl: String

    var song: Song {
        Song(
            id: id,
            title: title,
            artistName: artistName,
            artistId: nil,
            albumTitle: nil,
            coverURL: URL(string: artworkUrl),
            duration: 0
        )
    }
}

struct PlayHistoryEntry: Codable, Sendable {
    let trackId: String
    let title: String
    let artistName: String
    let artistId: String?
    let coverUrl: String?
    let genre: String?
    let playedAt: Date
    let secondsPlayed: Double
    let completed: Bool
}

/// One artist on the way to the server's reference list.
struct ReferenceArtistUpload: Codable, Sendable {
    let id: String
    let name: String
    let tracks: Int
    let albums: Int
}

struct ReferenceUploadResult: Codable, Sendable {
    let stored: Int
    let total: Int
}
