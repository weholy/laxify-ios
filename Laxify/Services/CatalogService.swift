import Foundation

/// The catalogue.
///
/// Fetched from the source directly by the phone, with our own server as the
/// fallback. That is the opposite of how it started, and the reason is
/// measured rather than assumed: the app's own probe found every route to
/// our server unreachable on the network people use, while the source
/// answered on that same connection perfectly well.
///
/// Resolving streams here also fixes something a relay could not. The signed
/// media url is issued for whoever asked for it, so one obtained by a server
/// in Germany is refused on a phone elsewhere. A link this device resolves is
/// issued for this device.
///
/// The account — library, statistics, listening history — still comes from
/// our server. The two are independent: music plays whenever the source is
/// reachable, whether or not we are.
struct CatalogService: MusicService {
    static let shared = CatalogService()

    private var api: LaxifyAPI { LaxifyAPI.shared }

    // MARK: - Home

    func homeContent() async throws -> HomeContent {
        do {
            return try await homeFromServer()
        } catch {
            // The server is unreachable on some networks. Charts from the
            // source are a smaller home screen, but a working one.
            return try await homeFromSource()
        }
    }

    /// What to show when only the source can be reached.
    private func homeFromSource() async throws -> HomeContent {
        let popular = try await SoundCloudDirect.shared.charts(limit: 40)

        let collections = popular.isEmpty ? [] : [
            MusicCollection(
                id: "charts",
                title: "Сейчас слушают",
                subtitle: "Популярное прямо сейчас",
                coverURL: popular.first?.coverURL
            )
        ]

        return HomeContent(collections: collections, recommendedTracks: popular)
    }

    private func homeFromServer() async throws -> HomeContent {
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

        // Our server does this better — it filters out the accounts borrowing
        // famous names — but only when it can be reached. Asking one that
        // cannot costs a full timeout before the source is tried at all,
        // which is why searching took half a minute.
        if await LaxifyAPI.shared.isServerReachable,
           let viaServer = try? await searchThroughServer(trimmed) {
            return viaServer
        }

        let direct = try await SoundCloudDirect.shared.search(trimmed, limit: 30)
        return SearchResults(
            tracks: direct.tracks,
            artists: Self.ranked(direct.artists, for: trimmed),
            albums: direct.albums
        )
    }

    /// Puts the real artist first, without the server to ask.
    ///
    /// The source is open to anyone, so a name search returns the artist
    /// alongside fan accounts and reposters using the same name. The server
    /// checks each against an independent catalogue; here there is only what
    /// came back, so it is ordered by the signals that came with it — an
    /// exact name match, then how many people follow them.
    private static func ranked(_ artists: [MusicArtist], for query: String) -> [MusicArtist] {
        let needle = query
            .folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespaces)

        func score(_ artist: MusicArtist) -> Int {
            let name = artist.name
                .folding(options: .diacriticInsensitive, locale: .current)
                .lowercased()

            // Decoration around a name is common — "☆LiL PEEP☆" — so an exact
            // match is checked against the letters alone as well.
            let letters = name.filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
                .trimmingCharacters(in: .whitespaces)

            if name == needle || letters == needle { return 3 }
            if name.hasPrefix(needle) { return 2 }
            if name.contains(needle) { return 1 }
            return 0
        }

        return artists.sorted { lhs, rhs in
            let left = score(lhs)
            let right = score(rhs)
            if left != right { return left > right }
            return (lhs.trackCount ?? 0) > (rhs.trackCount ?? 0)
        }
    }

    private func searchThroughServer(_ trimmed: String) async throws -> SearchResults {
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
        if let direct = try? await SoundCloudDirect.shared.track(id).song {
            return direct
        }

        do {
            return try await api.catalogTrack(id: id).song
        } catch let error as APIError {
            throw Self.translate(error)
        }
    }

    func streamURL(for songId: String) async throws -> URL {
        // Resolved here so the signature belongs to this device. Going
        // through the server produced a link issued for Frankfurt, which is
        // refused anywhere else.
        try await SoundCloudDirect.shared.streamURL(for: songId)
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

        if let direct = try? await SoundCloudDirect.shared.artistTracks(
            artistId, limit: pageSize, offset: page * pageSize
        ), !direct.isEmpty {
            return direct
        }

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

    // MARK: - Discover

    func popularTracks() async throws -> [Song] {
        if await LaxifyAPI.shared.isServerReachable,
           let charts = try? await api.catalogCharts(limit: 50), !charts.isEmpty {
            return charts.map(\.song)
        }
        return try await SoundCloudDirect.shared.charts(limit: 50)
    }

    func categories() async throws -> [MusicCategory] {
        let genres = try await api.discoverGenres()
        return genres.map { MusicCategory(id: $0.id, title: $0.title) }
    }

    func categoryTracks(id: String, title: String, page: Int) async throws -> [Song] {
        // The genre listing is the better first page — it is ranked by plays.
        // It has no offset upstream, so the endless tail is paged search on
        // the genre's own name; the screen de-duplicates the seam.
        if page == 0,
           let listed = try? await api.discoverGenreTracks(genre: id, limit: 60),
           !listed.isEmpty {
            return listed.map(\.song)
        }

        return try await api
            .catalogSearchTracks(query: title, limit: 40, offset: page * 40)
            .map(\.song)
    }

    func suggestions(for query: String) async throws -> [String] {
        (try? await api.discoverSuggest(query: query)) ?? []
    }

    func categoryCoverURL(id: String) async -> URL? {
        if let tracks = try? await api.discoverGenreTracks(genre: id, limit: 6),
           let cover = tracks.compactMap({ $0.song.coverURL }).first {
            return cover
        }
        // Genre listing gave nothing — fall back to a plain search on the key.
        return await coverForQuery(id)
    }

    /// A representative cover for an arbitrary query — used for the wave
    /// settings tiles, which have no genre of their own.
    func coverForQuery(_ query: String) async -> URL? {
        if let tracks = try? await api.catalogSearchTracks(query: query, limit: 6),
           let cover = tracks.compactMap({ $0.song.coverURL }).first {
            return cover
        }
        return try? await SoundCloudDirect.shared.search(query, limit: 6).tracks
            .compactMap(\.coverURL).first
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
