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
    let birthdate: String?
    let isProfilePublic: Bool
    let isStatsPublic: Bool
    let hasCompletedOnboarding: Bool
    let isAdmin: Bool

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
