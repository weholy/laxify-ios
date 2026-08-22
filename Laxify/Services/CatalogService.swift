import Foundation

/// The catalogue, served through our own backend.
///
/// Everything the app plays comes from here. Talking to a music source
/// directly from the phone meant every listener needed a VPN for whatever
/// region that source happened to serve; routing through the server removes
/// that entirely — the server is somewhere the source answers, and the app
/// only ever talks to us.
///
/// It also means a source can be swapped, or a second one added behind the
/// first, without shipping a new build.
struct CatalogService: MusicService {
    static let shared = CatalogService()

    private var api: LaxifyAPI { LaxifyAPI.shared }

    // MARK: - Home

    func homeContent() async throws -> HomeContent {
        let feed = try await api.homeFeed(limit: 30)

        var collections: [MusicCollection] = []

        if !feed.wave.isEmpty {
            collections.append(
                MusicCollection(
                    id: "wave",
                    title: "Моя волна",
                    subtitle: "Подобрано по вашим вкусам",
                    coverURL: feed.wave.first?.artworkUrl.flatMap(URL.init(string:))
                )
            )
        }

        if !feed.forYou.isEmpty {
            collections.append(
                MusicCollection(
                    id: "for-you",
                    title: "Для вас",
                    subtitle: "Новое из того, что вы слушаете",
                    coverURL: feed.forYou.first?.artworkUrl.flatMap(URL.init(string:))
                )
            )
        }

        if !feed.charts.isEmpty {
            collections.append(
                MusicCollection(
                    id: "charts",
                    title: "Сейчас слушают",
                    subtitle: "Популярное прямо сейчас",
                    coverURL: feed.charts.first?.artworkUrl.flatMap(URL.init(string:))
                )
            )
        }

        // The wave leads the recommendations too — it is the list most likely
        // to be worth starting, and the home screen plays this row on tap.
        let recommended = feed.wave.isEmpty ? feed.charts : feed.wave

        return HomeContent(collections: collections, recommendedTracks: recommended.map(\.song))
    }

    // MARK: - Search

    func search(query: String) async throws -> SearchResults {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return SearchResults() }

        let response = try await api.catalogSearch(query: trimmed, limit: 30)

        let tracks = response.tracks.map(\.song)
        let artists = response.artists.map(\.artist)
        let albums = response.playlists.map {
            MusicAlbum(
                id: $0.id,
                title: $0.title,
                artistName: $0.ownerName ?? "",
                coverURL: $0.artworkUrl.flatMap(URL.init(string:)),
                year: nil
            )
        }

        return SearchResults(
            tracks: tracks,
            artists: artists,
            albums: albums,
            correctedQuery: nil,
            bestMatch: Self.bestMatch(for: trimmed, tracks: tracks, artists: artists)
        )
    }

    /// Decides what the top of the results should lead with.
    ///
    /// Searching an artist's name should surface the artist, not their most
    /// uploaded track — ranking purely by relevance score gets this wrong
    /// often enough to be noticeable.
    private static func bestMatch(
        for query: String, tracks: [Song], artists: [MusicArtist]
    ) -> SearchBestMatch {
        let needle = query.folding(options: .diacriticInsensitive, locale: .current).lowercased()

        if let artist = artists.first {
            let name = artist.name.folding(options: .diacriticInsensitive, locale: .current).lowercased()
            if name == needle || name.hasPrefix(needle) {
                return .artist
            }
        }

        if let track = tracks.first {
            let title = track.title.folding(options: .diacriticInsensitive, locale: .current).lowercased()
            if title == needle || title.hasPrefix(needle) {
                return .track
            }
        }

        return artists.isEmpty ? .track : .other
    }

    // MARK: - Tracks

    func song(id: String) async throws -> Song {
        do {
            return try await api.catalogTrack(id: id).song
        } catch let error as APIError {
            throw Self.translate(error)
        }
    }

    func streamURL(for songId: String) async throws -> URL {
        do {
            return try await api.catalogStreamURL(trackId: songId)
        } catch let error as APIError {
            throw Self.translate(error)
        }
    }

    // MARK: - Artists

    func artistDetail(artistId: String) async throws -> ArtistDetail {
        do {
            let detail = try await api.catalogArtistDetail(id: artistId)

            return ArtistDetail(
                artist: detail.artist.artist,
                topTracks: detail.topTracks.map(\.song),
                // Releases first, then anything the artist merely collected.
                releases: detail.releases.map(\.album),
                similarArtists: detail.similarArtists.map(\.artist)
            )
        } catch let error as APIError {
            throw Self.translate(error)
        }
    }

    func artistTracks(artistId: String, page: Int) async throws -> [Song] {
        let pageSize = 50
        return try await api
            .catalogArtistTracks(id: artistId, limit: pageSize, offset: page * pageSize)
            .map(\.song)
    }

    // MARK: - Collections

    func playlistTracks(collectionId: String) async throws -> (title: String, songs: [Song]) {
        switch collectionId {
        case "wave":
            let wave = try await api.wave(limit: 60)
            return ("Моя волна", wave.tracks.map(\.song))
        case "charts":
            return ("Сейчас слушают", try await api.catalogCharts(limit: 50).map(\.song))
        default:
            let tracks = try await api.catalogPlaylistTracks(id: collectionId)
            return ("Подборка", tracks.map(\.song))
        }
    }

    func albumDetail(albumId: String) async throws -> (album: MusicAlbum, songs: [Song]) {
        let tracks = try await api.catalogPlaylistTracks(id: albumId).map(\.song)

        let album = MusicAlbum(
            id: albumId,
            title: tracks.first?.albumTitle ?? "Подборка",
            artistName: tracks.first?.artistName ?? "",
            coverURL: tracks.first?.coverURL,
            year: nil
        )
        return (album, tracks)
    }

    // MARK: - Errors

    /// Maps transport failures onto something the screens already handle.
    private static func translate(_ error: APIError) -> Error {
        switch error {
        case .server(let status, _) where status == 404:
            MusicServiceError.notFound
        case .notAuthenticated:
            MusicServiceError.missingAccessKey
        default:
            MusicServiceError.underlying(error)
        }
    }
}
