import Foundation
@preconcurrency import YMAPI

actor YandexMusicService: MusicService {
    static let shared = YandexMusicService()

    private var isReady = false

    private init() {}

    func homeContent() async throws -> HomeContent {
        try await ensureReady()

        let newPlaylists = try await run { YMClient.shared.getNewPlaylists(completion: $0) }
        let playlistIds = (newPlaylists.newPlaylists ?? []).prefix(10)

        var collections: [MusicCollection] = []
        var recommendedTracks: [Song] = []

        for playlistId in playlistIds {
            guard let playlists = try? await run({ completion in
                YMClient.shared.getPlaylists(userId: String(playlistId.uid), playlistsId: [String(playlistId.kind)], completion: completion)
            }), let playlist = playlists.first else { continue }

            collections.append(collection(from: playlist))
            if recommendedTracks.isEmpty {
                recommendedTracks = (playlist.tracks ?? []).compactMap(\.track).map(song(from:))
            }
        }

        return HomeContent(collections: collections, recommendedTracks: recommendedTracks)
    }

    func search(query: String) async throws -> SearchResults {
        try await ensureReady()

        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return SearchResults()
        }

        let result = try await run { completion in
            YMClient.shared.search(text: query, noCorrect: false, type: .all, page: 0, includeBestPlaylists: false, completion: completion)
        }

        return SearchResults(
            tracks: (result.tracks?.results ?? []).map(song(from:)),
            artists: (result.artists?.results ?? []).map(musicArtist(from:)),
            albums: (result.albums?.results ?? []).map(musicAlbum(from:))
        )
    }

    func artistDetail(artistId: String) async throws -> ArtistDetail {
        try await ensureReady()

        let artists = try await run { YMClient.shared.getArtists(artistIds: [artistId], completion: $0) }
        guard let artist = artists.first else {
            throw MusicServiceError.notFound
        }

        async let tracksResult = run { YMClient.shared.getArtistTracks(artistId: artistId, page: 0, pageSize: 10, completion: $0) }
        async let albumsResult = run { YMClient.shared.getArtistDirectAlbums(artistId: artistId, page: 0, pageSize: 10, sortBy: .year, completion: $0) }

        let tracks = try await tracksResult
        let albums = try await albumsResult

        return ArtistDetail(
            artist: musicArtist(from: artist),
            topTracks: tracks.tracks.map(song(from:)),
            releases: albums.albums.map(musicAlbum(from:)),
            similarArtists: []
        )
    }

    func streamURL(for songId: String) async throws -> URL {
        try await ensureReady()

        let tracks = try await run { YMClient.shared.getTracks(trackIds: [songId], positions: false, completion: $0) }
        guard let track = tracks.first else {
            throw MusicServiceError.notFound
        }

        let link = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            track.getDownloadLink(codec: .mp3, bitrate: .kbps_192) { result in
                switch result {
                case .success(let link):
                    continuation.resume(returning: link)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }

        guard let url = URL(string: link) else {
            throw MusicServiceError.notFound
        }
        return url
    }

    private func ensureReady() async throws {
        guard !isReady else { return }
        guard let key = AppSecrets.accessKey else {
            throw MusicServiceError.missingAccessKey
        }

        let device = YMDevice.generateWebMimicDevice(uuid: DeviceIdentity.uuid)
        _ = YMClient.initialize(device: device, lang: .ru, uid: -1, token: "", xToken: key)

        _ = try await run { completion in
            YMClient.shared.generateYMTokenFromXToken(xToken: key, completion: completion)
        }

        isReady = true
    }
}
