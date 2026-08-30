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
            // No fallback to the raw source. Its uploads are titled by
            // whoever posted them, and one screen full of those undoes the
            // clean catalogue everywhere else — better an empty home with a
            // retry than a home that looks like a different app.
            throw error
        }
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

        // Only the server searches. It answers from the proper catalogue —
        // real names, artist photos, albums, playlists — while the source's
        // own search returns uploads titled by whoever posted them. Mixing
        // the two is what made results look like two different apps.
        return try await searchThroughServer(trimmed)
    }

    private func searchThroughServer(_ trimmed: String) async throws -> SearchResults {
        let response = try await api.catalogSearch(query: trimmed, limit: 30)

        let tracks = response.tracks.map(\.song)
        let artists = response.artists.map(\.artist)

        func asAlbum(_ p: CatalogPlaylistDTO) -> MusicAlbum {
            MusicAlbum(
                id: p.id,
                title: p.title,
                artistName: p.ownerName ?? "",
                coverURL: p.artworkUrl.flatMap(URL.init(string:)),
                year: p.year
            )
        }

        return SearchResults(
            tracks: tracks,
            artists: artists,
            albums: (response.albums ?? []).map(asAlbum),
            playlists: response.playlists.map(asAlbum),
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
        // The server first: it returns the track with the catalogue's name and
        // cover. The source knows the same track only by its uploader's
        // spelling, so it is the fallback, not the first choice.
        if let viaServer = try? await api.catalogTrack(id: id).song {
            return viaServer
        }

        if !Self.isSpotifyId(id),
           let direct = try? await SoundCloudDirect.shared.track(id).song {
            return direct
        }

        throw MusicServiceError.notFound
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

        // Ask the server, always: it filters an artist's uploads down to what
        // the proper catalogue actually credits to them. Going direct returns
        // every upload on the account, reposts and all, under whatever names
        // the uploader chose.
        return try await api
            .catalogArtistTracks(id: artistId, limit: pageSize, offset: page * pageSize)
            .map(\.song)
    }

    /// Spotify ids are 22-character base62; SoundCloud ids are all digits.
    static func isSpotifyId(_ value: String) -> Bool {
        !value.isEmpty
            && value.count >= 18
            && !value.allSatisfy(\.isNumber)
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
        try await api.catalogCharts(limit: 50).map(\.song)
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
