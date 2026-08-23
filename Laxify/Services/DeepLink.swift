import Foundation

enum DeepLink: Equatable, Hashable {
    case track(id: String)
    case artist(id: String)
    case album(id: String)
    case playlist(id: String)

    static let scheme = "laxify"

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme else { return nil }

        let host = url.host()?.lowercased()
        let pathParts = url.pathComponents.filter { $0 != "/" }
        guard let identifier = pathParts.first, !identifier.isEmpty else { return nil }

        switch host {
        case "track": self = .track(id: identifier)
        case "artist": self = .artist(id: identifier)
        case "album": self = .album(id: identifier)
        case "playlist": self = .playlist(id: identifier)
        default: return nil
        }
    }

    var url: URL? {
        switch self {
        // Escaped and optional: an id is whatever the source gave us, and a
        // link is not worth crashing over if one of them ever contains
        // something a url cannot hold.
        case .track(let id): Self.link("track", id)
        case .artist(let id): Self.link("artist", id)
        case .album(let id): Self.link("album", id)
        case .playlist(let id): Self.link("playlist", id)
        }
    }

    /// One link, escaped, or nothing.
    private static func link(_ kind: String, _ identifier: String) -> URL? {
        let allowed = CharacterSet.urlPathAllowed
        let escaped = identifier.addingPercentEncoding(withAllowedCharacters: allowed)
            ?? identifier
        return URL(string: "\(scheme)://\(kind)/\(escaped)")
    }
}

enum ShareText {
    static func track(_ song: Song) -> String {
        "\(song.title) — \(song.artistName)\n\(DeepLink.track(id: song.id).url?.absoluteString ?? "")"
    }

    static func artist(_ artist: MusicArtist) -> String {
        "\(artist.name)\n\(DeepLink.artist(id: artist.id).url?.absoluteString ?? "")"
    }

    static func album(_ album: MusicAlbum) -> String {
        "\(album.title) — \(album.artistName)\n\(DeepLink.album(id: album.id).url?.absoluteString ?? "")"
    }

    static func playlist(_ collection: MusicCollection) -> String {
        "\(collection.title)\n\(DeepLink.playlist(id: collection.id).url?.absoluteString ?? "")"
    }
}
