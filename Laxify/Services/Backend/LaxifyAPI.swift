import Foundation

enum APIError: LocalizedError {
    case notAuthenticated
    case server(status: Int, detail: String)
    case transport(Error)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            "Нужно войти в аккаунт"
        case .server(_, let detail):
            detail
        case .transport:
            "Нет связи с сервером"
        case .decoding:
            "Сервер вернул неожиданный ответ"
        }
    }
}

private struct ErrorBody: Decodable {
    let detail: String?
}

/// Client for the Laxify account server.
///
/// Handles the one piece of plumbing every call needs: attaching the access
/// token, and transparently refreshing it when the server says it expired.
actor LaxifyAPI {
    static let shared = LaxifyAPI()

    private let baseURL = URL(string: "https://laxify.31-76-27-182.sslip.io/api/v1")!
    private let session: URLSession

    /// Guards against a burst of 401s each kicking off its own refresh — the
    /// server rotates refresh tokens, so a second concurrent refresh would
    /// present an already-used token and invalidate the whole session.
    private var refreshTask: Task<Bool, Never>?

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            // The server emits fractional seconds inconsistently depending on
            // the column, so try both rather than failing the whole payload.
            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withFraction.date(from: text) { return date }

            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: text) { return date }

            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Не удалось разобрать дату: \(text)"
            )
        }
        return decoder
    }()

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    var isSignedIn: Bool {
        KeychainStore.read(.accessToken) != nil
    }

    // MARK: - Auth

    func signInWithGoogle(idToken: String, deviceName: String) async throws -> BackendSessionResponse {
        struct Body: Encodable {
            let idToken: String
            let device: Device
            struct Device: Encodable {
                let name: String
                let model: String?
                let appVersion: String?
            }
        }

        let body = Body(
            idToken: idToken,
            device: .init(
                name: deviceName,
                model: nil,
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            )
        )

        let response: BackendSessionResponse = try await send(
            "/auth/google", method: "POST", body: body, authenticated: false
        )
        store(response.tokens)
        return response
    }

    func signOut() async {
        if let refresh = KeychainStore.read(.refreshToken) {
            struct Body: Encodable { let refreshToken: String }
            _ = try? await send(
                "/auth/logout",
                method: "POST",
                body: Body(refreshToken: refresh),
                authenticated: false
            ) as MessageResponse
        }
        KeychainStore.clear()
    }

    // MARK: - Profile

    func currentUser() async throws -> BackendUser {
        try await send("/me", method: "GET")
    }

    func completeOnboarding(
        displayName: String,
        username: String,
        birthdate: Date?,
        avatarURL: String?
    ) async throws -> BackendUser {
        struct Body: Encodable {
            let displayName: String
            let username: String
            let birthdate: String?
            let avatarUrl: String?
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        return try await send(
            "/me/onboarding",
            method: "POST",
            body: Body(
                displayName: displayName,
                username: username,
                birthdate: birthdate.map(formatter.string(from:)),
                avatarUrl: avatarURL
            )
        )
    }

    func updateProfile(
        displayName: String?,
        username: String?,
        birthdate: Date?,
        clearBirthdate: Bool
    ) async throws -> BackendUser {
        struct Body: Encodable {
            let displayName: String?
            let username: String?
            let birthdate: String?
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        return try await send(
            "/me",
            method: "PATCH",
            body: Body(
                displayName: displayName,
                username: username,
                birthdate: clearBirthdate ? nil : birthdate.map(formatter.string(from:))
            )
        )
    }

    func checkUsername(_ username: String) async throws -> UsernameAvailability {
        try await send("/users/username-available?username=\(username)", method: "GET")
    }

    // MARK: - Library

    func favorites() async throws -> [BackendFavorite] {
        let page: BackendPage<BackendFavorite> = try await send("/me/favorites?limit=500", method: "GET")
        return page.items
    }

    func addFavorite(_ song: Song) async throws {
        try await addFavorite(track: BackendTrack(song: song), addedAt: Date())
    }

    /// Replays a queued like with its original timestamp, so an item that sat
    /// in the outbox for a day does not land as if it were liked just now.
    func addFavorite(track: BackendTrack, addedAt: Date) async throws {
        struct Body: Encodable {
            let track: BackendTrack
            let addedAt: Date
        }
        _ = try await send(
            "/me/favorites",
            method: "PUT",
            body: Body(track: track, addedAt: addedAt)
        ) as BackendFavorite
    }

    func removeFavorite(trackId: String) async throws {
        _ = try await send("/me/favorites/\(trackId)", method: "DELETE") as MessageResponse
    }

    func dislikes() async throws -> [String] {
        try await send("/me/dislikes", method: "GET")
    }

    func addDislike(trackId: String) async throws {
        struct Body: Encodable { let trackId: String }
        _ = try await send(
            "/me/dislikes", method: "PUT", body: Body(trackId: trackId)
        ) as MessageResponse
    }

    // MARK: - Activity

    func reportPlayback(_ events: [PlaybackEvent]) async throws {
        guard !events.isEmpty else { return }
        struct Body: Encodable { let events: [PlaybackEvent] }
        _ = try await send("/me/playback", method: "POST", body: Body(events: events)) as BackendStats
    }

    func registerDownload(song: Song, sizeBytes: Int) async throws {
        struct Body: Encodable {
            let track: BackendTrack
            let sizeBytes: Int
        }
        _ = try await send(
            "/me/downloads",
            method: "PUT",
            body: Body(track: BackendTrack(song: song), sizeBytes: sizeBytes)
        ) as MessageResponse
    }

    func removeDownload(trackId: String) async throws {
        _ = try await send("/me/downloads/\(trackId)", method: "DELETE") as MessageResponse
    }

    func stats() async throws -> BackendStats {
        try await send("/me/stats", method: "GET")
    }

    func migrateLocalData(
        favorites: [(song: Song, addedAt: Date)],
        dislikedTrackIds: [String],
        totalSecondsListened: Double
    ) async throws {
        struct FavoritePayload: Encodable {
            let trackId: String
            let title: String
            let artistName: String
            let artistId: String?
            let albumTitle: String?
            let coverUrl: String?
            let durationSeconds: Double
            let addedAt: Date
        }
        struct Body: Encodable {
            let favorites: [FavoritePayload]
            let dislikedTrackIds: [String]
            let totalSecondsListened: Double
        }

        let payload = favorites.map { entry in
            FavoritePayload(
                trackId: entry.song.id,
                title: entry.song.title,
                artistName: entry.song.artistName,
                artistId: entry.song.artistId,
                albumTitle: entry.song.albumTitle,
                coverUrl: entry.song.coverURL?.absoluteString,
                durationSeconds: entry.song.duration,
                addedAt: entry.addedAt
            )
        }

        struct Result: Decodable { let favoritesImported: Int }
        _ = try await send(
            "/me/migrate-local",
            method: "POST",
            body: Body(
                favorites: payload,
                dislikedTrackIds: dislikedTrackIds,
                totalSecondsListened: totalSecondsListened
            )
        ) as Result
    }

    // MARK: - Transport

    private func store(_ tokens: BackendTokens) {
        KeychainStore.save(tokens.accessToken, for: .accessToken)
        KeychainStore.save(tokens.refreshToken, for: .refreshToken)
    }

    private func send<Response: Decodable>(
        _ path: String,
        method: String,
        authenticated: Bool = true
    ) async throws -> Response {
        try await perform(path, method: method, bodyData: nil, authenticated: authenticated)
    }

    private func send<Body: Encodable, Response: Decodable>(
        _ path: String,
        method: String,
        body: Body,
        authenticated: Bool = true
    ) async throws -> Response {
        let data = try encoder.encode(body)
        return try await perform(path, method: method, bodyData: data, authenticated: authenticated)
    }

    private func perform<Response: Decodable>(
        _ path: String,
        method: String,
        bodyData: Data?,
        authenticated: Bool,
        isRetry: Bool = false
    ) async throws -> Response {
        guard let url = URL(string: baseURL.absoluteString + path) else {
            throw APIError.server(status: 0, detail: "Некорректный адрес запроса")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = bodyData
        if bodyData != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        if authenticated {
            guard let token = KeychainStore.read(.accessToken) else {
                throw APIError.notAuthenticated
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.server(status: 0, detail: "Некорректный ответ сервера")
        }

        if http.statusCode == 401, authenticated, !isRetry {
            guard await refreshSession() else {
                KeychainStore.clear()
                throw APIError.notAuthenticated
            }
            return try await perform(
                path, method: method, bodyData: bodyData, authenticated: true, isRetry: true
            )
        }

        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? decoder.decode(ErrorBody.self, from: data))?.detail
            throw APIError.server(
                status: http.statusCode,
                detail: detail ?? "Ошибка сервера (\(http.statusCode))"
            )
        }

        if Response.self == MessageResponse.self, data.isEmpty {
            return MessageResponse(detail: "ok") as! Response
        }

        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    private func refreshSession() async -> Bool {
        if let existing = refreshTask {
            return await existing.value
        }

        let task = Task<Bool, Never> {
            guard let refreshToken = KeychainStore.read(.refreshToken) else { return false }

            struct Body: Encodable { let refreshToken: String }
            guard let url = URL(string: baseURL.absoluteString + "/auth/refresh"),
                  let bodyData = try? encoder.encode(Body(refreshToken: refreshToken)) else {
                return false
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = bodyData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            guard let (data, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let tokens = try? decoder.decode(BackendTokens.self, from: data) else {
                return false
            }

            store(tokens)
            return true
        }

        refreshTask = task
        let result = await task.value
        refreshTask = nil
        return result
    }
}
