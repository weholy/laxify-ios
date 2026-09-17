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

    /// Tracks whose listed upload will not stream, mapped to the upload of
    /// the same recording that will. Filled as they are found, kept for the
    /// launch — the catalogue keeps handing out the same dead ids, and there
    /// is no reason to rediscover the same answer on every play.
    private var substitutions: [String: String] = [:]

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
            return found
        }

        // Nothing new could be obtained. The key already in hand is worth
        // more than nil — it was working until something, most likely the
        // connection, stopped answering. Its timestamp is left alone so the
        // next call tries to refresh again rather than settling for it.
        return clientId
    }

    private func keyFromServer() async -> String? {
        try? await LaxifyAPI.shared.sourceKey()
    }

    /// The first shipped key the API still accepts.
    ///
    /// A key is only crossed off when the API actually refuses it. The moment
    /// the network stops answering, probing stops too and the first key is
    /// handed back unproven: nothing will work until the connection returns,
    /// and when it does this key very probably will.
    private func firstWorkingKnownKey() async -> String? {
        for candidate in Self.knownKeys {
            switch await accepts(candidate) {
            case .accepted:
                RemoteLog.shared.info(
                    "источник: ключ из приложения подошёл",
                    category: "source",
                    context: ["key": String(candidate.prefix(8))]
                )
                return candidate

            case .unreachable:
                RemoteLog.shared.warn(
                    "источник: сеть молчит, ключи не проверены",
                    category: "source",
                    context: ["берём": String(candidate.prefix(8))]
                )
                return candidate

            case .refused:
                continue
            }
        }

        RemoteLog.shared.warn("источник: ни один встроенный ключ не подошёл", category: "source")
        return nil
    }

    /// What checking a key actually told us.
    ///
    /// The third case is the one that matters. A request that never arrives
    /// says nothing about the key, and treating it as a refusal is what took
    /// the whole app down on a bad connection: every shipped key "failed" in
    /// turn against a network that was simply not answering, the scrape that
    /// follows failed for the same reason, and a set of perfectly good keys
    /// was thrown away — search, wave and playback with them.
    private enum KeyVerdict {
        case accepted
        case refused
        case unreachable
    }

    /// Whether the API answers for this key.
    ///
    /// Deliberately the smallest request there is, so checking four of them
    /// costs less than one page of search results.
    private func accepts(_ candidate: String) async -> KeyVerdict {
        var components = URLComponents(string: "\(Self.apiBase)/tracks")
        components?.queryItems = [
            URLQueryItem(name: "ids", value: "219590176"),
            URLQueryItem(name: "client_id", value: candidate)
        ]

        guard let url = components?.url else { return .refused }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8

        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200 ? .accepted : .refused
        } catch {
            RemoteLog.shared.warn(
                "источник: проверка ключа не прошла",
                category: "source",
                context: ["error": "\(error)", "вердикт": "сеть не ответила"]
            )
            return .unreachable
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
        retrying: Bool = false,
        attempt: Int = 0
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

        // Being throttled, or catching the source mid-wobble, says nothing
        // about this track. It used to: every non-2xx became `notFound`, the
        // player reads that as "this one will never play", and the track was
        // struck off for the session over a 429 that would have cleared in a
        // second. Wait, then ask again — twice, briefly, because a listener
        // is waiting on the other end of this.
        if status == 429 || (500..<600).contains(status) {
            guard attempt < 2 else {
                RemoteLog.shared.error(
                    "источник: источник не отвечает, попытки исчерпаны",
                    category: "source",
                    context: ["path": label, "status": "\(status)"]
                )
                throw MusicServiceError.temporarilyUnavailable
            }

            try? await Task.sleep(for: .milliseconds(attempt == 0 ? 400 : 1200))
            return try await request(
                path, query: query, absolute: absolute, retrying: retrying, attempt: attempt + 1
            )
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
    ///
    /// The upload the catalogue points at is not always the one that plays.
    /// The source serves some uploads — typically the label's own, which is
    /// also the one search ranks first — as FairPlay-encrypted HLS only:
    /// `progressive` and plain `hls` stay listed, but both resolve to a bare
    /// 404, and the encrypted variants need a licence only the source's own
    /// app can obtain. The same song is almost always up several times over,
    /// though, and the other copies stream normally. So a dead upload is not
    /// a dead song: when the listed one refuses, the same recording is found
    /// among the rest and played from there.
    /// What the app already knows about the song, from its own catalogue.
    ///
    /// Carried in so that a dead id is not the end of the road: when the
    /// source will not even describe the track, the title and length the app
    /// is already displaying are enough to go and find the same recording
    /// somewhere else.
    struct KnownTrack: Sendable {
        let title: String
        let artist: String
        /// Seconds, as the app has it.
        let duration: TimeInterval
    }

    func streamURL(for trackId: String, known: KnownTrack? = nil) async throws -> URL {
        // A substitution found earlier in this launch is reused directly:
        // the url itself expires and cannot be kept, but knowing *which*
        // upload to open saves the failed resolve and the search behind it
        // every time the track comes round again.
        if let previous = substitutions[trackId] {
            if let cached = try? await track(previous),
               case .url(let url) = await resolveStream(of: cached, trackId: previous) {
                return url
            }
            // The copy that rescued this track last time will not open now.
            // Forgetting it costs one search; keeping it would send every
            // future play at the same dead upload.
            substitutions[trackId] = nil
        }

        let track: SCItem
        do {
            track = try await self.track(trackId)
        } catch {
            // The source will not even describe it. If the app knows what the
            // song is, that is still enough to look for another copy.
            if let known,
               case .url(let rescued) = await substituteStream(
                   title: known.title,
                   artist: known.artist,
                   durationMs: known.duration * 1000,
                   excluding: trackId
               ) {
                return rescued
            }
            throw error
        }

        let outcome = await resolveStream(of: track, trackId: trackId)
        if case .url(let url) = outcome { return url }

        let rescue = await substituteStream(for: track, excluding: trackId)
        if case .url(let substitute) = rescue { return substitute }

        // Nothing opened — but *why* nothing opened is the whole question.
        // A source that never answered has said nothing about this track, and
        // reporting that as "this track does not exist" is what wrote working
        // songs out of the catalogue over a throttled minute. Only a source
        // that actually answered gets to condemn anything.
        var wentQuiet = false
        if case .unreachable = outcome { wentQuiet = true }
        if case .unreachable = rescue { wentQuiet = true }

        if wentQuiet {
            RemoteLog.shared.warn(
                "источник: не ответил при открытии потока",
                category: "source",
                context: ["track": trackId, "title": track.title ?? "-"]
            )
            throw MusicServiceError.temporarilyUnavailable
        }

        let transcodings = track.media?.transcodings ?? []
        let hasEncryptedOnly = transcodings.contains {
            ($0.format?.protocol_ ?? "").contains("encrypted")
        }

        RemoteLog.shared.error(
            hasEncryptedOnly
                ? "источник: заливка защищена и замены не нашлось"
                : "источник: ни один вариант не открылся",
            category: "source",
            context: [
                "track": trackId,
                "title": track.title ?? "-",
                "всего_вариантов": "\(transcodings.count)"
            ]
        )
        // `.confirmedUnavailable`, not the bare `.notFound` this file throws
        // elsewhere for far weaker reasons — by this point the source has
        // answered, resolving failed on a real (non-transient) verdict, and
        // a rescue search also found nothing safe. One track sitting at 447
        // failed attempts over two days (repeatedly re-served by the wave,
        // never reported as settled) is what not distinguishing this case
        // actually cost — see AudioPlayerController.isFinal.
        throw hasEncryptedOnly ? MusicServiceError.drmProtected : MusicServiceError.confirmedUnavailable
    }

    /// What came of trying to open one upload.
    ///
    /// The third case is the point of having an enum here at all. "No url"
    /// used to cover both a source that answered and had nothing, and a
    /// source that did not answer at all — and the caller, unable to tell
    /// them apart, treated both as a dead track.
    private enum StreamOutcome {
        case url(URL)
        /// The source answered, and none of its variants lead anywhere.
        case dead
        /// The source did not answer. Says nothing about the track.
        case unreachable
    }

    /// Opens one upload.
    private func resolveStream(of track: SCItem, trackId: String) async -> StreamOutcome {
        guard let transcodings = track.media?.transcodings, !transcodings.isEmpty else {
            RemoteLog.shared.warn(
                "источник: у трека нет вариантов потока",
                category: "source",
                context: ["track": trackId, "policy": track.policy ?? "-"]
            )
            return .dead
        }

        // Progressive MP3 first: it plays directly and supports seeking.
        // Every variant is tried, because a track can advertise several and
        // only some of them answer.
        // A preview is not the track. A `SNIP` upload, or a variant marked
        // `snipped`, streams thirty seconds and ends — and the player reports
        // that as the track finishing normally, so the listener heard half a
        // minute and then the next song. Treated as nothing to play here,
        // which sends the track to the server for the whole recording.
        guard track.policy != "SNIP" else {
            RemoteLog.shared.info(
                "источник: доступен только отрывок",
                category: "source",
                context: ["track": trackId]
            )
            return .dead
        }

        let ranked = transcodings
            .filter { ["progressive", "hls"].contains($0.format?.protocol_ ?? "") }
            .filter { $0.snipped != true }
            .sorted { lhs, rhs in
                (lhs.format?.protocol_ == "progressive" ? 0 : 1)
                    < (rhs.format?.protocol_ == "progressive" ? 0 : 1)
            }

        // Set the moment any variant fails for a reason that is about the
        // network rather than about the upload. One of those anywhere in the
        // list is enough to make the whole verdict provisional.
        var sourceWentQuiet = false

        for candidate in ranked {
            guard let link = candidate.url else { continue }

            var query: [URLQueryItem] = []
            if let authorization = track.trackAuthorization {
                query.append(URLQueryItem(name: "track_authorization", value: authorization))
            }

            struct Resolved: Decodable { let url: String? }

            do {
                let resolved = try await decode(Resolved.self, "", query: query, absolute: link)
                guard let text = resolved.url, let url = URL(string: text) else { continue }

                RemoteLog.shared.info(
                    "источник: ссылка получена",
                    category: "source",
                    context: ["track": trackId, "protocol": candidate.format?.protocol_ ?? "-"]
                )
                return .url(url)
            } catch {
                if Self.isTransient(error) { sourceWentQuiet = true }
                continue
            }
        }

        return sourceWentQuiet ? .unreachable : .dead
    }

    /// Whether a failure was the network or the source having a moment, as
    /// opposed to a verdict about the thing being asked for.
    ///
    /// Kept here as well as in the player because both sides have to agree:
    /// the player will not retry what this reports as final, and this must
    /// not report a timeout as final.
    nonisolated static func isTransient(_ error: Error) -> Bool {
        if case MusicServiceError.temporarilyUnavailable = error { return true }

        let underlying: Error
        if case MusicServiceError.underlying(let wrapped) = error {
            underlying = wrapped
        } else {
            underlying = error
        }

        guard let urlError = underlying as? URLError else { return false }

        switch urlError.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed,
             .notConnectedToInternet, .cannotFindHost, .resourceUnavailable,
             .internationalRoamingOff, .dataNotAllowed, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    /// Finds another upload of the same recording and opens that instead.
    ///
    /// Matched on length before anything else: a re-upload of the same master
    /// is within a second or two, while an acoustic version, a sped-up edit or
    /// a remix — all of which sit right next to the original in search — are
    /// not. Title has to look like the same song too, so a different track
    /// from the same artist cannot quietly take its place.
    private func substituteStream(for track: SCItem, excluding trackId: String) async -> StreamOutcome {
        guard let title = track.title else { return .dead }

        return await substituteStream(
            title: title,
            artist: track.publisherMetadata?.artist ?? track.user?.username ?? "",
            durationMs: (track.fullDuration ?? track.duration) ?? 0,
            excluding: trackId
        )
    }

    private func substituteStream(
        title: String, artist: String, durationMs wanted: Double, excluding trackId: String
    ) async -> StreamOutcome {
        guard wanted > 0 else { return .dead }

        let query = "\(artist) \(title)".trimmingCharacters(in: .whitespaces)

        let page: SCPage<SCItem>
        do {
            page = try await decode(
                SCPage<SCItem>.self,
                "search/tracks",
                query: [
                    URLQueryItem(name: "q", value: query),
                    URLQueryItem(name: "limit", value: "30")
                ]
            )
        } catch {
            // The last chance a track had, and it was the network that took
            // it. Saying "dead" here is how a song with a perfectly good
            // second copy waiting for it got struck off.
            return Self.isTransient(error) ? .unreachable : .dead
        }

        let target = Self.matchKey(title)
        var sourceWentQuiet = false

        for candidate in page.collection {
            guard let id = candidate.id.map(String.init), id != trackId,
                  let candidateTitle = candidate.title,
                  candidate.policy != "BLOCK", candidate.streamable != false,
                  // A preview of another upload is no better than a preview
                  // of this one.
                  candidate.policy != "SNIP",
                  // No sense resolving a copy that is locked the same way.
                  !candidate.isDRMOnly
            else { continue }

            // Five seconds, measured against what the source actually
            // returns: genuine re-uploads of one master come back between
            // 0.03s and 3s apart (different trailing silence, different
            // encoder), while the nearest thing that is *not* the same
            // recording — a mash-up — is 10s out, and acoustic takes and
            // remixes are 15s and beyond. The gap between the two groups is
            // wide, so the line goes in the middle of it rather than at the
            // edge of the first, which was throwing away good copies.
            let length = (candidate.fullDuration ?? candidate.duration) ?? 0
            guard abs(length - wanted) <= 5000 else { continue }
            guard Self.isSameSong(candidateTitle, as: title, target: target) else { continue }

            let opened = await resolveStream(of: candidate, trackId: id)
            guard case .url(let url) = opened else {
                if case .unreachable = opened { sourceWentQuiet = true }
                continue
            }

            substitutions[trackId] = id

            RemoteLog.shared.info(
                "источник: играем другую заливку",
                category: "source",
                context: [
                    "вместо": trackId,
                    "играем": id,
                    "title": candidateTitle,
                    "залил": candidate.user?.username ?? "-"
                ]
            )
            return .url(url)
        }

        return sourceWentQuiet ? .unreachable : .dead
    }

    /// Words that mean "this is a different take of that song".
    ///
    /// A remix keeps the original's name inside a longer title, and often its
    /// length too. Length alone therefore cannot tell them apart: a sped-up
    /// phonk remix of one track measured two seconds from the original and
    /// would have been played in its place.
    private static let versionMarkers = [
        "remix", "sped", "speed up", "speedup", "slowed", "reverb", "nightcore",
        "cover", "mashup", "mash up", "acoustic", "live", "instrumental",
        "karaoke", "edit", "bass boosted", "минус", "ремикс", "кавер", "ускорен",
        "замедлен", "живое"
    ]

    /// Whether a candidate is the same recording, not merely a title match.
    ///
    /// Substring containment on its own is far too generous — every remix
    /// contains the original's name. So a version marker the original does not
    /// carry disqualifies a candidate outright, and where the names are not
    /// simply equal, the shorter has to make up most of the longer rather than
    /// being a fragment buried in it.
    private static func isSameSong(_ candidate: String, as original: String, target: String) -> Bool {
        let lowered = candidate.lowercased()
        let originalLowered = original.lowercased()

        for marker in versionMarkers where lowered.contains(marker) && !originalLowered.contains(marker) {
            return false
        }

        let key = matchKey(candidate)
        guard !key.isEmpty, !target.isEmpty else { return false }
        if key == target { return true }

        let longer = key.count >= target.count ? key : target
        let shorter = key.count >= target.count ? target : key
        guard longer.contains(shorter) else { return false }

        // Two thirds, so "Моргенштерн - ДОМ" still matches "ДОМ" once the
        // artist prefix is off, while a title that merely mentions the song
        // among five other names does not.
        return Double(shorter.count) / Double(longer.count) >= 0.66
    }

    /// A title reduced to what identifies the song: lowercase letters and
    /// digits, with the artist prefix, feature credits and bracketed asides
    /// that re-uploaders add or drop at will taken out.
    private static func matchKey(_ title: String) -> String {
        var text = title.lowercased()

        for pattern in [#"\([^)]*\)"#, #"\[[^\]]*\]"#] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }

        // "Моргенштерн - ДОМ" and "ДОМ" are the same song filed two ways.
        if let dash = text.range(of: " - ") {
            text = String(text[dash.upperBound...])
        }

        return text
            .replacingOccurrences(of: #"[^\p{L}\p{N}]"#, with: "", options: .regularExpression)
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
    /// What the release itself says, as opposed to who uploaded it.
    let publisherMetadata: PublisherMetadata?

    struct PublisherMetadata: Decodable {
        let artist: String?
        let albumTitle: String?

        enum CodingKeys: String, CodingKey {
            case artist
            case albumTitle = "album_title"
        }
    }

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
        /// True for a preview-length variant of a track the viewer cannot
        /// hear in full.
        let snipped: Bool?
    }

    struct Format: Decodable {
        let protocol_: String?

        enum CodingKeys: String, CodingKey {
            case protocol_ = "protocol"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, title, username, duration, genre, policy, streamable, verified, description, user, media
        case publisherMetadata = "publisher_metadata"
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

    /// The artist the release credits, when it says anything useful.
    private var credited: String? {
        guard let name = publisherMetadata?.artist?.trimmingCharacters(in: .whitespaces),
              !name.isEmpty,
              // Some uploads put the label or a placeholder here.
              name.count < 60,
              name.lowercased() != "various artists"
        else { return nil }

        return name
    }

    /// Whether the source will only serve this under DRM.
    ///
    /// Free, and exact. A track that carries `cbc-encrypted-hls` /
    /// `ctr-encrypted-hls` variants has had its plain ones withdrawn: they
    /// stay listed and both answer 404, while the encrypted ones resolve to
    /// FairPlay, Widevine and PlayReady manifests that only the source's own
    /// player holds licences for. Measured across forty tracks pulled from
    /// search, the rule held every time — encrypted present meant the plain
    /// variant was dead, encrypted absent meant it played.
    ///
    /// So they are dropped here, before anything can list them. A track that
    /// cannot play should not be on the screen at all: it is the one that
    /// looks like the app skipping at random.
    var isDRMOnly: Bool {
        media?.transcodings?.contains {
            ($0.format?.protocol_ ?? "").contains("encrypted")
        } ?? false
    }

    var song: Song? {
        guard kind == "track", let id, let title else { return nil }
        // A blocked track will not play, so it should never be offered.
        guard policy != "BLOCK", streamable != false else { return nil }
        // Note: `isDRMOnly` is deliberately *not* a reason to hide a track.
        // On an artist's own page nineteen of twenty uploads can be locked —
        // filtering here emptied MORGENSHTERN's page down to a single song.
        // The same recording is almost always up elsewhere unlocked, so these
        // are played by substitution at the moment of playing instead. Only a
        // track with no substitute anywhere is dropped, and that is decided
        // then, not here.
        //
        // Which is what this is: the ones already proven dead on this device,
        // locked with nothing to fall back to. Whether a track is rescuable
        // cannot be known without going and looking, so it is learned once,
        // the hard way, and then never repeated.
        guard !UnplayableStore.contains("\(id)") else { return nil }

        // What the release credits, before who uploaded it. An account is
        // called "☆LiL PEEP☆" or "everlov3d"; the release says "Lil Peep".
        // The second is the artist, the first is a username — and when there
        // is no credit at all, the title itself usually carries the name.
        let cleaned = TrackTitle.clean(
            title: title,
            artist: credited ?? user?.username,
            artistIsCredited: credited != nil
        )

        return Song(
            id: "\(id)",
            title: cleaned.title,
            artists: Self.credits(cleaned.artist ?? "Неизвестный исполнитель", uploader: user),
            albumTitle: publisherMetadata?.albumTitle,
            // full_duration is the real length; duration can be a preview
            // window for tracks the viewer cannot hear in full.
            coverURL: Self.upsized(artworkUrl ?? user?.avatarUrl),
            duration: (fullDuration ?? duration ?? 0) / 1000,
            rawTitle: title
        )
    }

    /// A credit line turned into per-artist entries, each tappable only when
    /// its identity is actually known.
    ///
    /// The response carries exactly one artist id — the uploader's — no
    /// matter how many names the release credits ("MORGENSHTERN,
    /// ELDZHEY"). Handing that one id to every split name is what made
    /// tapping the second artist on a track open the first artist's
    /// profile instead: every name pointed at the same id because there
    /// was only ever one to give out. Matched by username where possible;
    /// otherwise the first credited name is assumed to be the uploader
    /// (the ordinary "main artist, feature" convention) and gets the id,
    /// the rest stay present but untappable rather than guessing wrong.
    private static func credits(_ credited: String, uploader: User?) -> [SongArtist] {
        let names = TrackTitle.splitCredited(credited)
        let uploaderId = uploader?.id.map(String.init) ?? ""
        guard names.count > 1 else {
            return [SongArtist(id: uploaderId, name: credited)]
        }

        let uploaderName = (uploader?.username ?? "").lowercased()
        let matched = names.firstIndex { $0.lowercased() == uploaderName }

        return names.enumerated().map { index, name in
            let isUploader = matched.map { $0 == index } ?? (index == 0)
            return SongArtist(id: isUploader ? uploaderId : "", name: name)
        }
    }

    var artist: MusicArtist? {
        guard let id, let username else { return nil }

        return MusicArtist(
            id: "\(id)",
            name: username,
            imageURL: Self.upsized(avatarUrl),
            bio: description,
            trackCount: trackCount,
            albumCount: nil,
            isVerified: verified ?? false,
            followers: followersCount
        )
    }
}
