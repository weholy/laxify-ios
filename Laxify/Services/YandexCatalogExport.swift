import Foundation

/// Collects artists from Yandex Music into a file.
///
/// This runs on the phone rather than on the server for one reason: the
/// server cannot reach that API at all — it answers 451 from where the server
/// is. A phone in Russia can, so the device is the only place this can happen.
///
/// There is no call that lists every artist, so the catalogue is walked. The
/// obvious way — searching each letter of the alphabet — turns out to return
/// mostly classical composers, whose enormous catalogues outrank everyone on
/// a bare prefix; a first attempt collected Beethoven and Handel while
/// missing every rapper anyone actually searches for.
///
/// So it walks the similar-artist graph instead. Starting from the charts and
/// following "listeners also like" reaches the artists people care about,
/// because that is exactly what the relation encodes. The letter search runs
/// afterwards as a supplement, to catch anyone the graph does not connect.
@MainActor
@Observable
final class YandexCatalogExport {
    static let shared = YandexCatalogExport()

    struct Artist: Codable, Sendable {
        let id: String
        let name: String
        /// How many people follow them. Only present on full artist records,
        /// which is one reason the graph walk beats searching.
        let likes: Int?
        let tracks: Int?
        let albums: Int?
        let genres: [String]
        /// Set for compilation entries — "Various Artists" and the like,
        /// which are not people and should not be matched against accounts.
        let isVarious: Bool
        let coverURL: String?
        /// Which pass found them, so the file says how it was assembled.
        let via: String
    }

    enum Phase: Equatable {
        case idle
        case running(stage: String, done: Int, total: Int, found: Int)
        case finished(count: Int, file: URL)
        case failed(String)
    }

    private(set) var phase: Phase = .idle

    private var task: Task<Void, Never>?

    /// How far the graph walk goes. Reached in practice long before the
    /// request budget, and enough to cover anything with an audience.
    private static let artistCap = 20_000
    private static let requestCap = 2_500

    private static let searchTerms: [String] = {
        let cyrillic = "абвгдежзиклмнопрстуфхцчшэюя".map(String.init)
        let latin = "abcdefghijklmnopqrstuvwxyz".map(String.init)
        let words = [
            "рэп", "хип хоп", "поп", "рок", "шансон", "лсп", "гуф",
            "lil", "young", "dj", "mc", "big", "king", "boy", "girl", "trap"
        ]
        return cyrillic + latin + words
    }()

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    func start() {
        guard !isRunning else { return }
        guard let token = AppSecrets.accessKey else {
            phase = .failed("Нет ключа доступа")
            return
        }

        task = Task { await run(token: token) }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    // MARK: - The walk

    private func run(token: String) async {
        let client = YandexClient(token: token)

        var collected: [String: Artist] = [:]
        var requests = 0

        // MARK: Seeds — who is being listened to right now.

        phase = .running(stage: "Ищем популярных", done: 0, total: 1, found: 0)

        var frontier = await client.chartArtists()
        requests += 1

        for genre in YandexClient.seedGenres {
            if Task.isCancelled { return }
            frontier += await client.genreArtists(genre)
            requests += 1
            phase = .running(stage: "Ищем популярных", done: requests, total: 1 + YandexClient.seedGenres.count, found: 0)
        }

        var queue = Array(Set(frontier))
        var visited = Set<String>()

        guard !queue.isEmpty else {
            phase = .failed("Каталог не ответил — проверьте, что ключ ещё действует")
            return
        }

        // MARK: The graph — everyone those artists lead to.

        while let id = queue.first, collected.count < Self.artistCap, requests < Self.requestCap {
            queue.removeFirst()

            if Task.isCancelled { return }
            guard visited.insert(id).inserted else { continue }

            let (artist, similar) = await client.artistAndSimilar(id)
            requests += 1

            if let artist, collected[artist.id] == nil {
                collected[artist.id] = artist
            }

            for neighbour in similar {
                if collected[neighbour.id] == nil {
                    collected[neighbour.id] = neighbour
                }
                if !visited.contains(neighbour.id) {
                    queue.append(neighbour.id)
                }
            }

            phase = .running(
                stage: "Обходим похожих",
                done: requests,
                total: Self.requestCap,
                found: collected.count
            )

            // Gentle on purpose: this is somebody else's service and the
            // export is not in a hurry.
            try? await Task.sleep(for: .milliseconds(90))
        }

        // MARK: Supplement — anyone the graph never connected to.

        let terms = Self.searchTerms
        for (index, term) in terms.enumerated() {
            if Task.isCancelled { return }

            for page in 0..<3 {
                let found = await client.searchArtists(term, page: page)
                if found.isEmpty { break }

                for artist in found where collected[artist.id] == nil {
                    collected[artist.id] = artist
                }

                try? await Task.sleep(for: .milliseconds(90))
            }

            phase = .running(
                stage: "Дочищаем по алфавиту",
                done: index + 1,
                total: terms.count,
                found: collected.count
            )
        }

        guard !collected.isEmpty else {
            phase = .failed("Ничего не собралось")
            return
        }

        let sorted = Array(collected.values).sorted {
            ($0.likes ?? 0, $0.tracks ?? 0) > ($1.likes ?? 0, $1.tracks ?? 0)
        }

        // Straight to the server, which is what actually uses this. The file
        // is still written, but only so it can be looked at — the list takes
        // effect the moment this finishes rather than after someone passes a
        // file around.
        phase = .running(stage: "Отправляем список", done: 1, total: 1, found: sorted.count)
        await upload(sorted)

        do {
            let file = try write(sorted)
            phase = .finished(count: sorted.count, file: file)
        } catch {
            phase = .failed("Не удалось сохранить файл")
        }
    }

    /// Hands the list to the server, replacing what it had.
    ///
    /// A full collection replaces rather than adds: an artist who has left
    /// the catalogue should leave ours too, and merging would keep them
    /// forever.
    private func upload(_ artists: [Artist]) async {
        let payload = artists.map {
            ReferenceArtistUpload(
                id: $0.id,
                name: $0.name,
                tracks: $0.tracks ?? 0,
                albums: $0.albums ?? 0
            )
        }

        do {
            let result = try await LaxifyAPI.shared.uploadReference(payload, replace: true)
            AppLogger.log("export: отправлено \(result.stored), всего \(result.total)")
        } catch {
            AppLogger.log("export: не удалось отправить список — \(error)")
        }
    }

    private func write(_ artists: [Artist]) throws -> URL {
        struct Export: Encodable {
            let source = "yandex"
            let method = "chart seeds, similar-artist graph, alphabet supplement"
            let exportedAt: Date
            let count: Int
            let artists: [Artist]
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(
            Export(exportedAt: Date(), count: artists.count, artists: artists)
        )

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("laxify-artists.json")
        try data.write(to: url, options: .atomic)

        return url
    }
}

// MARK: - The API

/// The handful of calls this export needs, written directly.
///
/// Direct rather than through the wrapper package because the walk cares
/// about exactly what comes back, including the responses that are empty.
private struct YandexClient: Sendable {
    let token: String

    private static let base = "https://api.music.yandex.net"

    /// Genres broad enough to seed the graph from every corner of it.
    static let seedGenres = [
        "rap", "pop", "rusrap", "ruspop", "rock", "electronic",
        "dance", "indie", "alternative", "rnb", "shanson", "local-indie"
    ]

    private var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration)
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async -> T? {
        var components = URLComponents(string: Self.base + path)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
        // The catalogue answers a mobile client more fully than an unnamed one.
        request.setValue("YandexMusicAndroid/24023621", forHTTPHeaderField: "X-Yandex-Music-Client")

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return nil
        }

        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Artist ids from the chart — the seeds everything else grows from.
    func chartArtists() async -> [String] {
        guard let payload: ChartResponse = await get("/landing3/chart") else { return [] }

        let tracks = payload.result.chart?.tracks ?? []
        return tracks.flatMap { entry in (entry.artists ?? []).map { String($0.id) } }
    }

    func genreArtists(_ genre: String) async -> [String] {
        guard let payload: ChartResponse = await get(
            "/landing3/chart", query: [URLQueryItem(name: "genre", value: genre)]
        ) else { return [] }

        let tracks = payload.result.chart?.tracks ?? []
        return tracks.flatMap { entry in (entry.artists ?? []).map { String($0.id) } }
    }

    /// One artist and everyone the catalogue says they sound like.
    func artistAndSimilar(
        _ id: String
    ) async -> (YandexCatalogExport.Artist?, [YandexCatalogExport.Artist]) {
        guard let payload: BriefInfoResponse = await get("/artists/\(id)/brief-info") else {
            return (nil, [])
        }

        let artist = payload.result.artist.map { convert($0, via: "graph") }
        let similar = (payload.result.similarArtists ?? []).map { convert($0, via: "graph") }
        return (artist, similar)
    }

    func searchArtists(_ term: String, page: Int) async -> [YandexCatalogExport.Artist] {
        guard let payload: SearchResponse = await get(
            "/search",
            query: [
                URLQueryItem(name: "text", value: term),
                URLQueryItem(name: "type", value: "artist"),
                URLQueryItem(name: "page", value: "\(page)"),
                URLQueryItem(name: "nocorrect", value: "true")
            ]
        ) else { return [] }

        return (payload.result.artists?.results ?? []).map { convert($0, via: "search") }
    }

    private func convert(_ entry: ArtistEntry, via: String) -> YandexCatalogExport.Artist {
        YandexCatalogExport.Artist(
            id: String(entry.id),
            name: entry.name,
            likes: entry.likesCount,
            tracks: entry.counts?.tracks,
            albums: entry.counts?.directAlbums,
            genres: entry.genres ?? [],
            isVarious: entry.various ?? false,
            coverURL: entry.cover?.uri,
            via: via
        )
    }

    // MARK: Shapes

    private struct ChartResponse: Decodable {
        let result: Result
        struct Result: Decodable { let chart: Chart? }
        struct Chart: Decodable { let tracks: [Track]? }
        struct Track: Decodable { let artists: [Reference]? }
        struct Reference: Decodable { let id: Int }
    }

    private struct BriefInfoResponse: Decodable {
        let result: Result
        struct Result: Decodable {
            let artist: ArtistEntry?
            let similarArtists: [ArtistEntry]?
        }
    }

    private struct SearchResponse: Decodable {
        let result: Result
        struct Result: Decodable { let artists: Artists? }
        struct Artists: Decodable { let results: [ArtistEntry] }
    }

    struct ArtistEntry: Decodable {
        let id: Int
        let name: String
        let likesCount: Int?
        let various: Bool?
        let genres: [String]?
        let counts: Counts?
        let cover: Cover?

        struct Counts: Decodable {
            let tracks: Int?
            let directAlbums: Int?
        }

        struct Cover: Decodable {
            let uri: String?
        }
    }
}
