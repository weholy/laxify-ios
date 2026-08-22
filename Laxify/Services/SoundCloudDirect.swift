import Foundation

/// Talks to the music source from the phone.
///
/// Everything used to go through our own server, which resolved streams and
/// relayed the audio. That turned out to be the thing standing between
/// listeners and their music: the probe found all five routes to the server
/// unreachable on the network people actually use, while the source itself
/// answers there perfectly well — its own app works on the same connection.
///
/// So the catalogue is fetched here. It also fixes something the relay could
/// never fix: the signed media url is issued for the region that asked for
/// it, so a link resolved by a server in Germany is refused elsewhere. A link
/// the phone resolves is issued for the phone.
///
/// The account — library, statistics, the wave's history — still lives on our
/// server. The two are independent now: music plays whenever the source is
/// reachable, whether or not we are.
actor SoundCloudDirect {
    static let shared = SoundCloudDirect()

    private static let apiBase = "https://api-v2.soundcloud.com"
    private static let webBase = "https://soundcloud.com"

    /// The same user agent the web player sends. The API answers a browser
    /// more completely than an unnamed client.
    private static let userAgent = """
        Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 \
        (KHTML, like Gecko) Chrome/122.0 Safari/537.36
        """

    /// Keys the web player has used, kept in the app.
    ///
    /// The official app does not read the website to find one — it ships
    /// with a key. Scraping the site first was a mistake for the same reason
    /// asking our server first was: the site is a separate host that can be
    /// unreachable while the API is fine, and depending on it made music
    /// depend on something music does not need.
    ///
    /// Each is checked against the API itself, so a key that has been retired
    /// is skipped rather than trusted.
    private static let knownKeys = [
        "0dqfiN6c3Y9idZWFzMMulqPjotmYCC7S",
        "iZIs9mchVcX5lhVRyQGGAYlNPVldzAoX",
        "a3e059563d7fd3372b49b37f00a00bcf",
        "2t9loNQH90kzJcsFCODdigxfp325aq4z"
    ]

    private var clientId: String?
    private var clientIdFetchedAt: Date?
    private var clientIdTask: Task<String?, Never>?

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = ["User-Agent": SoundCloudDirect.userAgent]
        return URLSession(configuration: configuration)
    }()

    // MARK: - The key

    /// The web player's own key, read out of the page that uses it.
    ///
    /// There is nothing to register for; the key is public and rotates, so it
    /// is read once, kept, and read again when the source stops accepting it.
    private func key(refreshing: Bool = false) async -> String? {
        if !refreshing,
           let clientId,
           let fetchedAt = clientIdFetchedAt,
           Date().timeIntervalSince(fetchedAt) < 6 * 3600 {
            return clientId
        }

        if let clientIdTask, !refreshing {
            return await clientIdTask.value
        }

        // A key we already have, checked against the API, costs one request
        // and needs nothing but the API itself. Only when none of them still
        // work is anything else asked.
        let task = Task<String?, Never> { [weak self] in
            guard let self else { return nil }

            if let known = await self.firstWorkingKnownKey() {
                return known
            }
            if let scraped = await self.scrapeKey() {
                return scraped
            }
            return await self.keyFromServer()
        }

        clientIdTask = task
        let found = await task.value
        clientIdTask = nil

        if let found {
            clientId = found
            clientIdFetchedAt = Date()
        }

        return found
    }

    private func keyFromServer() async -> String? {
        try? await LaxifyAPI.shared.sourceKey()
    }

    /// The first shipped key the API still accepts.
    private func firstWorkingKnownKey() async -> String? {
        for candidate in Self.knownKeys {
            if await accepts(candidate) {
                RemoteLog.shared.info(
                    "источник: ключ из приложения подошёл",
                    category: "source",
                    context: ["key": String(candidate.prefix(8))]
                )
                return candidate
            }
        }

        RemoteLog.shared.warn("источник: ни один встроенный ключ не подошёл", category: "source")
        return nil
    }

    /// Whether the API answers for this key.
    ///
    /// Deliberately the smallest request there is, so checking four of them
    /// costs less than one page of search results.
    private func accepts(_ candidate: String) async -> Bool {
        var components = URLComponents(string: "\(Self.apiBase)/tracks")
        components?.queryItems = [
            URLQueryItem(name: "ids", value: "219590176"),
            URLQueryItem(name: "client_id", value: candidate)
        ]

        guard let url = components?.url else { return false }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8

        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            RemoteLog.shared.warn(
                "источник: проверка ключа не прошла",
                category: "source",
                context: ["error": "\(error)"]
            )
            return false
        }
    }

    /// Reads the key out of the web player's own scripts.
    ///
    /// Logged at every step. This is the first thing that has to work, and
    /// when it does not, nothing downstream gives any hint why — which is
    /// exactly the situation this had to be diagnosed from.
    private func scrapeKey() async -> String? {
        guard let home = URL(string: Self.webBase) else { return nil }

        let started = Date()
        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(from: home)
        } catch {
            RemoteLog.shared.error(
                "источник: страница не открылась",
                category: "source",
                context: ["error": "\(error)"]
            )
            return nil
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        RemoteLog.shared.timing(
            "источник: страница открыта",
            milliseconds: Int(Date().timeIntervalSince(started) * 1000),
            category: "source",
            context: ["status": "\(status)", "bytes": "\(data.count)"]
        )

        guard let html = String(data: data, encoding: .utf8) else {
            RemoteLog.shared.error("источник: страница не читается", category: "source")
            return nil
        }

        let scriptPattern = /src="(https:\/\/a-v2\.sndcdn\.com\/assets\/[^"]+\.js)"/
        let scripts = html.matches(of: scriptPattern).map { String($0.1) }

        RemoteLog.shared.info(
            "источник: скриптов в разметке",
            category: "source",
            context: ["count": "\(scripts.count)"]
        )

        guard !scripts.isEmpty else {
            RemoteLog.shared.error("источник: скриптов нет в разметке", category: "source")
            return nil
        }

        // The key lives in one of the later bundles, so walk them newest
        // first rather than downloading all of them.
        for (index, script) in scripts.reversed().enumerated() {
            guard let url = URL(string: script),
                  let (body, _) = try? await session.data(from: url),
                  let text = String(data: body, encoding: .utf8) else {
                continue
            }

            let keyPattern = /client_id[:=]"([a-zA-Z0-9]{32})"/
            if let match = text.firstMatch(of: keyPattern) {
                RemoteLog.shared.info(
                    "источник: ключ получен",
                    category: "source",
                    context: ["bundle": "\(index)"]
                )
                return String(match.1)
            }
        }

        RemoteLog.shared.error(
            "источник: ключа нет ни в одном скрипте",
            category: "source",
            context: ["scripts": "\(scripts.count)"]
        )
        return nil
    }

    /// Fetches a key and reports why if it cannot.
    ///
    /// Used by the diagnostics screen, which needs the reason rather than
    /// just the absence.
    func diagnosticKey() async throws -> String {
        guard let found = await key(refreshing: true) else {
            throw NSError(
                domain: "Laxify",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Не удалось получить ключ источника. Подробности — в записях ниже."
                ]
            )
        }
        return found
    }

    // MARK: - Requests

    private func request(
        _ path: String,
        query: [URLQueryItem] = [],
        absolute: String? = nil,
        retrying: Bool = false
    ) async throws -> Data {
        guard let clientId = await key(refreshing: retrying) else {
            throw MusicServiceError.notFound
        }

        var components = URLComponents(string: absolute ?? "\(Self.apiBase)/\(path)")
        components?.queryItems = query + [URLQueryItem(name: "client_id", value: clientId)]

        guard let url = components?.url else { throw MusicServiceError.notFound }

        let label = path.isEmpty ? (absolute ?? "?") : path

        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(from: url)
        } catch {
            // A cancelled request means the screen that wanted it went away,
            // which is ordinary navigation rather than something broken.
            let cancelled = (error as? URLError)?.code == .cancelled
            if cancelled {
                RemoteLog.shared.info(
                    "источник: запрос отменён",
                    category: "source",
                    context: ["path": label]
                )
            } else {
                RemoteLog.shared.error(
                    "источник: запрос не прошёл",
                    category: "source",
                    context: ["path": label, "error": "\(error)"]
                )
            }
            throw MusicServiceError.underlying(error)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if status != 200 {
            RemoteLog.shared.warn(
                "источник: ответ \(status)",
                category: "source",
                context: ["path": label]
            )
        }

        if (status == 401 || status == 403), !retrying {
            // The key rotated; read a fresh one and try once more.
            return try await request(path, query: query, absolute: absolute, retrying: true)
        }

        guard (200..<300).contains(status) else {
            throw MusicServiceError.notFound
        }

        return data
    }

    private func decode<T: Decodable>(
        _ type: T.Type,
        _ path: String,
        query: [URLQueryItem] = [],
        absolute: String? = nil
    ) async throws -> T {
        let data = try await request(path, query: query, absolute: absolute)
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Catalogue

    func search(_ term: String, limit: Int = 30) async throws -> SearchResults {
        let page: SCPage<SCItem> = try await decode(
            SCPage<SCItem>.self,
            "search",
            query: [
                URLQueryItem(name: "q", value: term),
                URLQueryItem(name: "limit", value: "\(limit)")
            ]
        )

        var tracks: [Song] = []
        var artists: [MusicArtist] = []

        for item in page.collection {
            switch item.kind {
            case "track": if let song = item.song { tracks.append(song) }
            case "user": if let artist = item.artist { artists.append(artist) }
            default: break
            }
        }

        return SearchResults(tracks: tracks, artists: artists, albums: [])
    }

    func searchTracks(_ term: String, limit: Int = 30, offset: Int = 0) async throws -> [Song] {
        let page: SCPage<SCItem> = try await decode(
            SCPage<SCItem>.self,
            "search/tracks",
            query: [
                URLQueryItem(name: "q", value: term),
                URLQueryItem(name: "limit", value: "\(limit)"),
                URLQueryItem(name: "offset", value: "\(offset)")
            ]
        )
        return page.collection.compactMap(\.song)
    }

    func track(_ id: String) async throws -> SCItem {
        let items: [SCItem] = try await decode(
            [SCItem].self, "tracks", query: [URLQueryItem(name: "ids", value: id)]
        )
        guard let first = items.first else { throw MusicServiceError.notFound }
        return first
    }

    func stationTracks(_ trackId: String, limit: Int = 50) async throws -> [Song] {
        let page: SCPage<SCItem> = try await decode(
            SCPage<SCItem>.self,
            "stations/soundcloud:track-stations:\(trackId)/tracks",
            query: [URLQueryItem(name: "limit", value: "\(limit)")]
        )
        return page.collection.compactMap(\.song)
    }

    func charts(genre: String = "all-music", limit: Int = 30) async throws -> [Song] {
        struct ChartPage: Decodable {
            struct Entry: Decodable { let track: SCItem? }
            let collection: [Entry]
        }

        let page: ChartPage = try await decode(
            ChartPage.self,
            "charts",
            query: [
                URLQueryItem(name: "kind", value: "trending"),
                URLQueryItem(name: "genre", value: "soundcloud:genres:\(genre)"),
                URLQueryItem(name: "limit", value: "\(limit)")
            ]
        )
        return page.collection.compactMap { $0.track?.song }
    }

    func artistTracks(_ artistId: String, limit: Int = 50, offset: Int = 0) async throws -> [Song] {
        let page: SCPage<SCItem> = try await decode(
            SCPage<SCItem>.self,
            "users/\(artistId)/tracks",
            query: [
                URLQueryItem(name: "limit", value: "\(limit)"),
                URLQueryItem(name: "offset", value: "\(offset)")
            ]
        )
        return page.collection.compactMap(\.song)
    }

    func artist(_ id: String) async throws -> MusicArtist {
        let item: SCItem = try await decode(SCItem.self, "users/\(id)")
        guard let artist = item.artist else { throw MusicServiceError.notFound }
        return artist
    }

    // MARK: - Playback

    /// A playable url, resolved here so the signature is issued for this
    /// device rather than for a server somewhere else.
    func streamURL(for trackId: String) async throws -> URL {
        let track = try await track(trackId)

        guard let transcodings = track.media?.transcodings, !transcodings.isEmpty else {
            RemoteLog.shared.error(
                "источник: у трека нет вариантов потока",
                category: "source",
                context: ["track": trackId, "policy": track.policy ?? "-"]
            )
            throw MusicServiceError.notFound
        }

        // Progressive MP3 first: it plays directly and supports seeking.
        // Every variant is tried, because a track can advertise several and
        // only some of them answer.
        let ranked = transcodings
            .filter { ["progressive", "hls"].contains($0.format?.protocol_ ?? "") }
            .sorted { lhs, rhs in
                (lhs.format?.protocol_ == "progressive" ? 0 : 1)
                    < (rhs.format?.protocol_ == "progressive" ? 0 : 1)
            }

        for candidate in ranked {
            guard let link = candidate.url else { continue }

            var query: [URLQueryItem] = []
            if let authorization = track.trackAuthorization {
                query.append(URLQueryItem(name: "track_authorization", value: authorization))
            }

            struct Resolved: Decodable { let url: String? }

            guard let resolved = try? await decode(Resolved.self, "", query: query, absolute: link),
                  let text = resolved.url,
                  let url = URL(string: text) else {
                continue
            }

            RemoteLog.shared.info(
                "источник: ссылка получена",
                category: "source",
                context: ["track": trackId, "protocol": candidate.format?.protocol_ ?? "-"]
            )
            return url
        }

        RemoteLog.shared.error(
            "источник: ни один вариант не открылся",
            category: "source",
            context: ["track": trackId, "variants": "\(ranked.count)"]
        )
        throw MusicServiceError.notFound
    }
}

// MARK: - Shapes

/// A page of results, whatever they are.
struct SCPage<Element: Decodable>: Decodable {
    let collection: [Element]
}

/// One thing the source can return — a track, a user, or a playlist.
///
/// They arrive mixed in the same array, told apart by `kind`, so one shape
/// covers all of them rather than three that mostly overlap.
struct SCItem: Decodable {
    let id: Int?
    let kind: String?
    let title: String?
    let username: String?
    let permalinkUrl: String?
    let artworkUrl: String?
    let avatarUrl: String?
    let duration: Double?
    let fullDuration: Double?
    let genre: String?
    let policy: String?
    let streamable: Bool?
    let playbackCount: Int?
    let followersCount: Int?
    let trackCount: Int?
    let verified: Bool?
    let description: String?
    let trackAuthorization: String?
    let user: User?
    let media: Media?

    struct User: Decodable {
        let id: Int?
        let username: String?
        let avatarUrl: String?
        let verified: Bool?

        enum CodingKeys: String, CodingKey {
            case id, username, verified
            case avatarUrl = "avatar_url"
        }
    }

    struct Media: Decodable {
        let transcodings: [Transcoding]?
    }

    struct Transcoding: Decodable {
        let url: String?
        let quality: String?
        let format: Format?
    }

    struct Format: Decodable {
        let protocol_: String?

        enum CodingKeys: String, CodingKey {
            case protocol_ = "protocol"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, title, username, duration, genre, policy, streamable, verified, description, user, media
        case permalinkUrl = "permalink_url"
        case artworkUrl = "artwork_url"
        case avatarUrl = "avatar_url"
        case fullDuration = "full_duration"
        case playbackCount = "playback_count"
        case followersCount = "followers_count"
        case trackCount = "track_count"
        case trackAuthorization = "track_authorization"
    }

    /// Artwork at a size worth showing. The source hands out 100px by
    /// default, which looks broken at any real size.
    private static func upsized(_ url: String?) -> URL? {
        guard let url else { return nil }
        return URL(
            string: url
                .replacingOccurrences(of: "-large.jpg", with: "-t500x500.jpg")
                .replacingOccurrences(of: "-small.jpg", with: "-t500x500.jpg")
        )
    }

    var song: Song? {
        guard kind == "track", let id, let title else { return nil }
        // A blocked track will not play, so it should never be offered.
        guard policy != "BLOCK", streamable != false else { return nil }

        return Song(
            id: "\(id)",
            title: title,
            artistName: user?.username ?? "Неизвестный исполнитель",
            artistId: user?.id.map(String.init),
            albumTitle: nil,
            // full_duration is the real length; duration can be a preview
            // window for tracks the viewer cannot hear in full.
            coverURL: Self.upsized(artworkUrl ?? user?.avatarUrl),
            duration: (fullDuration ?? duration ?? 0) / 1000
        )
    }

    var artist: MusicArtist? {
        guard let id, let username else { return nil }

        return MusicArtist(
            id: "\(id)",
            name: username,
            imageURL: Self.upsized(avatarUrl),
            bio: description,
            trackCount: trackCount,
            albumCount: nil
        )
    }
}
