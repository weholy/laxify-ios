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

    var url: URL {
        switch self {
        case .track(let id): URL(string: "\(Self.scheme)://track/\(id)")!
        case .artist(let id): URL(string: "\(Self.scheme)://artist/\(id)")!
        case .album(let id): URL(string: "\(Self.scheme)://album/\(id)")!
        case .playlist(let id): URL(string: "\(Self.scheme)://playlist/\(id)")!
        }
    }
}

enum ShareText {
    static func track(_ song: Song) -> String {
        "\(song.title) — \(song.artistName)\n\(DeepLink.track(id: song.id).url.absoluteString)"
    }

    static func artist(_ artist: MusicArtist) -> String {
        "\(artist.name)\n\(DeepLink.artist(id: artist.id).url.absoluteString)"
    }

    static func album(_ album: MusicAlbum) -> String {
        "\(album.title) — \(album.artistName)\n\(DeepLink.album(id: album.id).url.absoluteString)"
    }

    static func playlist(_ collection: MusicCollection) -> String {
        "\(collection.title)\n\(DeepLink.playlist(id: collection.id).url.absoluteString)"
    }
}
