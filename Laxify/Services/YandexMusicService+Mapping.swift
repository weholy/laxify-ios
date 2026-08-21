import Foundation
@preconcurrency import YMAPI

extension YandexMusicService {
    func run<T>(_ operation: @escaping (@escaping (Result<T, YMError>) -> Void) -> Void) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            operation { result in
                switch result {
                case .success(let value):
                    continuation.resume(returning: value)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func coverURL(from template: String?, size: Int = 400) -> URL? {
        guard let template, !template.isEmpty else { return nil }
        let resolved = template.replacingOccurrences(of: "%%", with: "\(size)x\(size)")
        return URL(string: "https://" + resolved)
    }

    func song(from track: Track) -> Song {
        Song(
            id: track.trackId,
            title: track.trackTitle,
            artistName: track.artistsName.joined(separator: ", "),
            artistId: track.artists.first.map { String($0.id) },
            albumTitle: track.albums.first?.title,
            coverURL: coverURL(from: track.coverUri),
            duration: TimeInterval(track.durationMs) / 1000
        )
    }

    func musicArtist(from artist: Artist) -> MusicArtist {
        MusicArtist(
            id: String(artist.id),
            name: artist.artistName,
            imageURL: coverURL(from: artist.cover?.uri),
            bio: artist.description?.text,
            trackCount: artist.counts?.tracks,
            albumCount: artist.counts?.directAlbums
        )
    }

    func musicAlbum(from album: Album) -> MusicAlbum {
        MusicAlbum(
            id: album.id.map(String.init) ?? UUID().uuidString,
            title: album.title ?? "",
            artistName: album.artistsName.joined(separator: ", "),
            coverURL: coverURL(from: album.coverUri),
            year: album.year
        )
    }

    func collection(from playlist: Playlist) -> MusicCollection {
        MusicCollection(
            id: "\(playlist.uid ?? 0)_\(playlist.kind ?? 0)",
            title: playlist.title,
            subtitle: playlist.trackCount.map { "\($0) треков" },
            coverURL: coverURL(from: playlist.cover?.uri)
        )
    }
}
