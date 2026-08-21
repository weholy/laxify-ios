import Foundation
@preconcurrency import YMAPI

actor YandexMusicService: MusicService {
    static let shared = YandexMusicService()

    private var isReady = false

    private init() {}

    private static let fallbackSearchTerms = ["хиты", "поп музыка", "рэп", "рок"]

    func homeContent() async throws -> HomeContent {
        try await ensureReady()

        var collections: [MusicCollection] = []
        var recommendedTracks: [Song] = []

        if let newPlaylists = try? await run({ YMClient.shared.getNewPlaylists(completion: $0) }) {
            let playlistIds = (newPlaylists.newPlaylists ?? []).prefix(10)
            for playlistId in playlistIds {
                guard let playlists = try? await run({ completion in
                    YMClient.shared.getPlaylists(userId: String(playlistId.uid), playlistsId: [String(playlistId.kind)], completion: completion)
                }), let playlist = playlists.first else { continue }

                collections.append(collection(from: playlist))
                if recommendedTracks.isEmpty {
                    recommendedTracks = await resolvedTracks(for: playlist)
                }
            }
        }

        if recommendedTracks.isEmpty {
            for term in Self.fallbackSearchTerms {
                guard let results = try? await search(query: term) else { continue }
                recommendedTracks.append(contentsOf: results.tracks)
                if recommendedTracks.count >= 15 { break }
            }
        }

        guard !collections.isEmpty || !recommendedTracks.isEmpty else {
            throw MusicServiceError.notFound
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

        let results = mapSearch(result)
        guard results.isEmpty else { return results }

        // Nothing matched as typed — retry with the spelling correction the
        // service suggests, so a typo shows close matches instead of a dead end.
        guard let corrected = result.misspellResult,
              !corrected.isEmpty,
              corrected.caseInsensitiveCompare(query) != .orderedSame else {
            return results
        }

        let retry = try await run { completion in
            YMClient.shared.search(text: corrected, noCorrect: true, type: .all, page: 0, includeBestPlaylists: false, completion: completion)
        }

        var corrected_results = mapSearch(retry)
        corrected_results.correctedQuery = corrected
        return corrected_results
    }

    private func mapSearch(_ result: Search) -> SearchResults {
        SearchResults(
            tracks: (result.tracks?.results ?? []).map(song(from:)),
            artists: (result.artists?.results ?? []).map(musicArtist(from:)),
            albums: (result.albums?.results ?? []).map(musicAlbum(from:)),
            bestMatch: SearchBestMatch(rawValue: result.best?.type ?? "") ?? .other
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

    func song(id: String) async throws -> Song {
        try await ensureReady()

        let tracks = try await run { YMClient.shared.getTracks(trackIds: [id], positions: false, completion: $0) }
        guard let track = tracks.first else {
            throw MusicServiceError.notFound
        }
        return song(from: track)
    }

    func albumDetail(albumId: String) async throws -> (album: MusicAlbum, songs: [Song]) {
        try await ensureReady()

        let album = try await run { YMClient.shared.getAlbumWithTracksData(albumId: albumId, completion: $0) }
        let tracks = (album.volumes ?? []).flatMap { $0 }
        guard !tracks.isEmpty else {
            throw MusicServiceError.notFound
        }
        return (musicAlbum(from: album), tracks.map(song(from:)))
    }

    func artistTracks(artistId: String, page: Int) async throws -> [Song] {
        try await ensureReady()

        let result = try await run { completion in
            YMClient.shared.getArtistTracks(artistId: artistId, page: page, pageSize: 50, completion: completion)
        }
        return result.tracks.map(song(from:))
    }

    func waveTracks(seedArtistIds: [String]) async throws -> [Song] {
        try await ensureReady()

        guard !seedArtistIds.isEmpty else { return [] }

        var collected: [Song] = []
        var seenIds: Set<String> = []

        for artistId in seedArtistIds.prefix(6) {
            guard let tracks = try? await artistTracks(artistId: artistId, page: 0) else { continue }
            for track in tracks.prefix(6) where !seenIds.contains(track.id) {
                seenIds.insert(track.id)
                collected.append(track)
            }
            if collected.count >= 30 { break }
        }

        return collected.shuffled()
    }

    func playlistTracks(collectionId: String) async throws -> (title: String, songs: [Song]) {
        try await ensureReady()

        let parts = collectionId.split(separator: "_")
        guard parts.count == 2 else { throw MusicServiceError.notFound }

        if parts[0] == "album" {
            let albumId = String(parts[1])
            let albums = try await run { YMClient.shared.getAlbums(albumIds: [albumId], completion: $0) }
            guard let album = albums.first else {
                throw MusicServiceError.notFound
            }
            let songs = (album.volumes ?? []).flatMap { $0 }.map(song(from:))
            return (album.title ?? "", songs)
        }

        let playlists = try await run { completion in
            YMClient.shared.getPlaylists(userId: String(parts[0]), playlistsId: [String(parts[1])], completion: completion)
        }
        guard let playlist = playlists.first else {
            throw MusicServiceError.notFound
        }

        let songs = await resolvedTracks(for: playlist)
        return (playlist.title, songs)
    }

    private func resolvedTracks(for playlist: Playlist) async -> [Song] {
        if playlist.tracks == nil || playlist.tracks?.isEmpty == true {
            _ = try? await run { completion in playlist.fetchTracks(completion: completion) }
        }
        return (playlist.tracks ?? []).compactMap(\.track).map(song(from:))
    }

    private func ensureReady() async throws {
        guard !isReady else { return }
        guard let key = AppSecrets.accessKey else {
            throw MusicServiceError.missingAccessKey
        }

        let device = YMDevice.generateWebMimicDevice(uuid: DeviceIdentity.uuid)

        _ = YMClient.initialize(device: device, lang: .ru, uid: -1, token: key, xToken: key)
        if let status = try? await run({ YMClient.shared.getAccountStatus(completion: $0) }),
           let uid = status.account?.uid {
            _ = YMClient.initialize(device: device, lang: .ru, uid: uid, token: key, xToken: key)
            isReady = true
            return
        }

        _ = YMClient.initialize(device: device, lang: .ru, uid: -1, token: "", xToken: key)
        _ = try await run { completion in
            YMClient.shared.generateYMTokenFromXToken(xToken: key, completion: completion)
        }

        isReady = true
    }
}
