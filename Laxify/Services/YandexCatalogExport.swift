import Foundation

/// Collects artists from Yandex Music into a file.
///
/// This runs on the phone rather than on the server for one reason: the
/// server cannot reach that API at all — it answers 451 from where the
/// server is. A phone in Russia can, so the device is the only place this
/// work can happen.
///
/// The catalogue has no "list every artist" call, so it is walked instead:
/// a wide set of search terms, paged through, deduplicated by id. That
/// reaches a large share of what anyone would actually look for, and each
/// artist arrives with the numbers needed to tell a real one from a name.
@MainActor
@Observable
final class YandexCatalogExport {
    static let shared = YandexCatalogExport()

    struct Artist: Codable, Sendable {
        let id: String
        let name: String
        /// How many people follow them, where the catalogue reports it.
        let likes: Int?
        let tracks: Int?
        let albums: Int?
        let genres: [String]
        /// Set for compilation entries — "Various Artists" and the like,
        /// which are not people and should not be matched against accounts.
        let isVarious: Bool
        let coverURL: String?
    }

    enum Phase: Equatable {
        case idle
        case running(done: Int, total: Int, found: Int)
        case finished(count: Int, file: URL)
        case failed(String)
    }

    private(set) var phase: Phase = .idle

    private var task: Task<Void, Never>?

    /// What gets searched for.
    ///
    /// Single letters find the most, since the catalogue matches on prefix;
    /// the syllables and common words reach names a bare letter ranks too
    /// low to return.
    private static let terms: [String] = {
        let cyrillic = "абвгдежзийклмнопрстуфхцчшщэюя".map(String.init)
        let latin = "abcdefghijklmnopqrstuvwxyz".map(String.init)
        let syllables = [
            "ка", "ро", "ли", "ма", "не", "по", "са", "то", "ша", "юр",
            "ba", "co", "da", "el", "gr", "jo", "ki", "lo", "mi", "ni",
            "pa", "ra", "se", "ta", "va", "yo", "zi"
        ]
        let words = [
            "рэп", "хип хоп", "поп", "рок", "джаз", "электро", "шансон",
            "lil", "young", "dj", "mc", "the", "big", "king", "boy", "girl"
        ]
        return cyrillic + latin + syllables + words
    }()

    /// Pages per term. Beyond this the results are mostly names that only
    /// coincidentally contain the term.
    private static let pagesPerTerm = 4

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

    private func run(token: String) async {
        var collected: [String: Artist] = [:]
        let terms = Self.terms
        let total = terms.count * Self.pagesPerTerm
        var done = 0

        phase = .running(done: 0, total: total, found: 0)

        let client = YandexSearchClient(token: token)

        for term in terms {
            for page in 0..<Self.pagesPerTerm {
                if Task.isCancelled { return }

                let artists = await client.artists(matching: term, page: page)
                done += 1

                for artist in artists where collected[artist.id] == nil {
                    collected[artist.id] = artist
                }

                phase = .running(done: done, total: total, found: collected.count)

                // Nothing on this page means nothing on the next either.
                if artists.isEmpty { break }

                // Gentle on purpose: this is somebody else's service and the
                // export is not in a hurry.
                try? await Task.sleep(for: .milliseconds(120))
            }
        }

        guard !collected.isEmpty else {
            phase = .failed("Ничего не найдено — проверьте, что ключ ещё действует")
            return
        }

        do {
            let file = try write(Array(collected.values).sorted { ($0.likes ?? 0) > ($1.likes ?? 0) })
            phase = .finished(count: collected.count, file: file)
        } catch {
            phase = .failed("Не удалось сохранить файл")
        }
    }

    private func write(_ artists: [Artist]) throws -> URL {
        struct Export: Encodable {
            let source = "yandex"
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

/// The one call this export needs, without the wrapper package.
///
/// Written directly because the export walks a single endpoint many times and
/// wants to see exactly what comes back, including the pages that return
/// nothing.
private struct YandexSearchClient: Sendable {
    let token: String

    private static let base = "https://api.music.yandex.net"

    private var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration)
    }

    func artists(matching term: String, page: Int) async -> [YandexCatalogExport.Artist] {
        var components = URLComponents(string: "\(Self.base)/search")
        components?.queryItems = [
            URLQueryItem(name: "text", value: term),
            URLQueryItem(name: "type", value: "artist"),
            URLQueryItem(name: "page", value: "\(page)"),
            URLQueryItem(name: "nocorrect", value: "true")
        ]

        guard let url = components?.url else { return [] }

        var request = URLRequest(url: url)
        request.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
        // The catalogue answers a mobile client more fully than an unnamed one.
        request.setValue("YandexMusicAndroid/24023621", forHTTPHeaderField: "X-Yandex-Music-Client")

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let payload = try? JSONDecoder().decode(SearchResponse.self, from: data)
        else { return [] }

        return (payload.result.artists?.results ?? []).map { entry in
            YandexCatalogExport.Artist(
                id: String(entry.id),
                name: entry.name,
                likes: entry.likesCount,
                tracks: entry.counts?.tracks,
                albums: entry.counts?.directAlbums,
                genres: entry.genres ?? [],
                isVarious: entry.various ?? false,
                coverURL: entry.cover?.uri
            )
        }
    }

    private struct SearchResponse: Decodable {
        let result: Result

        struct Result: Decodable {
            let artists: Artists?
        }

        struct Artists: Decodable {
            let results: [Entry]
        }

        struct Entry: Decodable {
            let id: Int
            let name: String
            let likesCount: Int?
            let various: Bool?
            let genres: [String]?
            let counts: Counts?
            let cover: Cover?
        }

        struct Counts: Decodable {
            let tracks: Int?
            let directAlbums: Int?
        }

        struct Cover: Decodable {
            let uri: String?
        }
    }
}
