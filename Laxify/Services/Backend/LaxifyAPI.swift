import Foundation
import UIKit

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

    /// Which route is in use, and the session that can talk to it.
    ///
    /// Both come from `APIRouter`, which finds a route that works on this
    /// network rather than assuming one. Reaching the server by address needs
    /// a session that verifies the certificate by the name it carries, so the
    /// session is chosen alongside the route.
    private var route: APIRoute = APIRoute.candidates[0]

    private var baseURL: URL { route.url }

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
        // A cold home feed assembles several upstream calls; twenty
        // seconds was close enough to that to time out on a slow link.
        configuration.timeoutIntervalForRequest = 45
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    /// Picks a route before the first request goes out, then reports what
    /// the network allowed.
    ///
    /// The report is the point: from the server there is no way to tell
    /// which routes a listener's network permits, and that is exactly what
    /// has to be known to stop guessing at it.
    func prepare() async {
        route = await APIRouter.shared.discover()

        let results = await APIRouter.shared.lastProbeResults
        guard !results.isEmpty else { return }

        struct Report: Encodable {
            let kind = "route-probe"
            let message: String
            let detail: String
            let osVersion: String
            let deviceModel: String
            let occurredAt = Date()
            let context: [String: String]
        }

        let summary = results
            .map { "\($0.key): \($0.value ? "доступен" : "нет")" }
            .sorted()
            .joined(separator: "\n")

        _ = await submitDiagnostic(
            Report(
                message: "Выбран маршрут \(route.base)",
                detail: summary,
                osVersion: await UIDevice.current.systemVersion,
                deviceModel: await UIDevice.current.model,
                context: results.mapValues { $0 ? "1" : "0" }
            )
        )
    }

    /// The session that can reach the current route.
    ///
    /// Reaching the server by address needs the trust evaluation that checks
    /// the certificate against the name it carries; every other route uses
    /// the ordinary one.
    private var activeSession: URLSession {
        route.skipsHostnameCheck ? APITrust.pinnedSession : session
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
        avatarURL: String?
    ) async throws -> BackendUser {
        struct Body: Encodable {
            let displayName: String
            let username: String
            let avatarUrl: String?
        }

        return try await send(
            "/me/onboarding",
            method: "POST",
            body: Body(displayName: displayName, username: username, avatarUrl: avatarURL)
        )
    }

    func updateProfile(
        displayName: String? = nil,
        username: String? = nil,
        bio: String? = nil,
        isProfilePublic: Bool? = nil,
        isStatsPublic: Bool? = nil,
        settings: [String: String]? = nil
    ) async throws -> BackendUser {
        struct Body: Encodable {
            let displayName: String?
            let username: String?
            let bio: String?
            let isProfilePublic: Bool?
            let isStatsPublic: Bool?
            let settings: [String: String]?
        }

        return try await send(
            "/me",
            method: "PATCH",
            body: Body(
                displayName: displayName,
                username: username,
                bio: bio,
                isProfilePublic: isProfilePublic,
                isStatsPublic: isStatsPublic,
                settings: settings
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

    // MARK: - Diagnostics

    func submitDiagnostic(_ body: some Encodable) async -> Bool {
        guard let url = URL(string: baseURL.absoluteString + "/diagnostics/report"),
              let data = try? encoder.encode(body) else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = KeychainStore.read(.accessToken) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else {
            return false
        }
        return (200..<300).contains(http.statusCode)
    }

    // MARK: - Transport

    private func store(_ tokens: BackendTokens) {
        KeychainStore.save(tokens.accessToken, for: .accessToken)
        KeychainStore.save(tokens.refreshToken, for: .refreshToken)
    }

    // MARK: - Email sign-in

    func requestEmailCode(email: String, purpose: String) async throws -> EmailCodeResponse {
        struct Body: Encodable {
            let email: String
            let purpose: String
        }
        return try await send(
            "/auth/email/request-code",
            method: "POST",
            body: Body(email: email, purpose: purpose),
            authenticated: false
        )
    }

    func verifyEmailCode(email: String, code: String, purpose: String) async throws -> EmailVerifiedResponse {
        struct Body: Encodable {
            let email: String
            let code: String
            let purpose: String
        }
        return try await send(
            "/auth/email/verify-code",
            method: "POST",
            body: Body(email: email, code: code, purpose: purpose),
            authenticated: false
        )
    }

    @discardableResult
    func setEmailPassword(
        email: String, code: String, password: String, purpose: String = "bind"
    ) async throws -> BackendSessionResponse {
        struct Body: Encodable {
            let email: String
            let code: String
            let password: String
            let purpose: String
            let deviceName: String
        }
        let session: BackendSessionResponse = try await send(
            "/auth/email/set-password",
            method: "POST",
            body: Body(
                email: email,
                code: code,
                password: password,
                purpose: purpose,
                deviceName: await UIDevice.current.name
            ),
            authenticated: false
        )
        store(session.tokens)
        return session
    }

    @discardableResult
    func signInWithEmail(email: String, password: String) async throws -> BackendSessionResponse {
        struct Body: Encodable {
            let email: String
            let password: String
            let deviceName: String
            let appVersion: String?
        }
        let session: BackendSessionResponse = try await send(
            "/auth/email/login",
            method: "POST",
            body: Body(
                email: email,
                password: password,
                deviceName: await UIDevice.current.name,
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ),
            authenticated: false
        )
        store(session.tokens)
        return session
    }

    @discardableResult
    func registerWithEmail(
        email: String, password: String, displayName: String? = nil
    ) async throws -> BackendSessionResponse {
        struct Body: Encodable {
            let email: String
            let password: String
            let displayName: String?
            let deviceName: String
        }
        let session: BackendSessionResponse = try await send(
            "/auth/email/register",
            method: "POST",
            body: Body(
                email: email,
                password: password,
                displayName: displayName,
                deviceName: await UIDevice.current.name
            ),
            authenticated: false
        )
        store(session.tokens)
        return session
    }

    func changeEmail(to email: String, code: String) async throws -> MessageResponse {
        struct Body: Encodable {
            let email: String
            let code: String
        }
        return try await send("/auth/email/change", method: "POST", body: Body(email: email, code: code))
    }

    func changePassword(current: String?, new: String) async throws -> MessageResponse {
        struct Body: Encodable {
            let currentPassword: String?
            let newPassword: String
        }
        return try await send(
            "/auth/email/password",
            method: "POST",
            body: Body(currentPassword: current, newPassword: new)
        )
    }

    /// Sends a batch of log lines.
    ///
    /// Unauthenticated, because the moments most worth seeing are the ones
    /// before anyone has managed to sign in.
    func sendLogs(
        sessionId: String,
        appVersion: String?,
        osVersion: String,
        deviceModel: String,
        entries: [RemoteLog.Entry]
    ) async -> Bool {
        struct Body: Encodable {
            let sessionId: String
            let appVersion: String?
            let osVersion: String
            let deviceModel: String
            let entries: [RemoteLog.Entry]
        }

        do {
            let _: MessageResponse = try await send(
                "/telemetry/logs",
                method: "POST",
                body: Body(
                    sessionId: sessionId,
                    appVersion: appVersion,
                    osVersion: osVersion,
                    deviceModel: deviceModel,
                    entries: entries
                ),
                authenticated: false
            )
            return true
        } catch {
            return false
        }
    }

    func lyrics(
        trackId: String, title: String, artist: String, duration: TimeInterval
    ) async throws -> LyricsResponse {
        let path = "/lyrics/\(escaped(trackId))"
            + "?title=\(escaped(title))"
            + "&artist=\(escaped(artist))"
            + "&duration=\(Int(duration))"
        return try await send(path, method: "GET")
    }

    /// Artwork for the sign-in screen.
    ///
    /// Unauthenticated: this is the one screen where nobody has a token yet,
    /// which is why asking an authenticated endpoint left it showing coloured
    /// squares.
    func showcase(limit: Int = 30) async throws -> [ShowcaseTrack] {
        try await send("/discover/showcase?limit=\(limit)", method: "GET", authenticated: false)
    }

    // MARK: - Listening statistics

    func replayPeriods() async throws -> [ReplayPeriod] {
        try await send("/replay/periods", method: "GET")
    }

    /// Everything the statistics screen opens with, in one round trip.
    func replayBundle() async throws -> ReplayBundle {
        try await send("/replay/bundle", method: "GET")
    }

    func replay(period: String) async throws -> ReplaySummary {
        try await send("/replay?period=\(escaped(period))&limit=10", method: "GET")
    }

    // MARK: - Catalogue

    /// Percent-encodes one query value.
    ///
    /// Search terms routinely contain spaces, `&` and `+`; the default allowed
    /// set leaves those intact, which silently truncates the query server-side.
    private func escaped(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    func catalogSearch(query: String, limit: Int = 30) async throws -> CatalogSearchResponse {
        try await send("/catalog/search?q=\(escaped(query))&limit=\(limit)", method: "GET")
    }

    func catalogSearchTracks(
        query: String, limit: Int = 30, offset: Int = 0
    ) async throws -> [CatalogTrackDTO] {
        try await send(
            "/catalog/search/tracks?q=\(escaped(query))&limit=\(limit)&offset=\(offset)",
            method: "GET"
        )
    }

    func catalogTrack(id: String) async throws -> CatalogTrackDTO {
        try await send("/catalog/tracks/\(escaped(id))", method: "GET")
    }

    func catalogStreamURL(trackId: String) async throws -> URL {
        let response: CatalogStreamResponse = try await send(
            "/catalog/tracks/\(escaped(trackId))/stream", method: "GET"
        )
        guard let url = URL(string: response.url) else {
            throw APIError.server(status: 0, detail: "Не удалось получить ссылку на трек")
        }
        return url
    }

    func catalogArtist(id: String) async throws -> CatalogArtistDTO {
        try await send("/catalog/artists/\(escaped(id))", method: "GET")
    }

    func catalogArtistDetail(id: String) async throws -> ArtistDetailResponse {
        try await send("/catalog/artists/\(escaped(id))/detail", method: "GET")
    }

    func catalogArtistTracks(
        id: String, limit: Int = 50, offset: Int = 0
    ) async throws -> [CatalogTrackDTO] {
        try await send(
            "/catalog/artists/\(escaped(id))/tracks?limit=\(limit)&offset=\(offset)",
            method: "GET"
        )
    }

    func catalogPlaylistTracks(id: String) async throws -> [CatalogTrackDTO] {
        try await send("/catalog/playlists/\(escaped(id))/tracks", method: "GET")
    }

    func catalogCharts(limit: Int = 30) async throws -> [CatalogTrackDTO] {
        try await send("/catalog/charts?limit=\(limit)", method: "GET")
    }

    /// Address and headers for streaming a track through this server.
    ///
    /// Returns nil when there is no session — the proxy is authenticated like
    /// everything else, and there is nothing useful to hand the player.
    func proxyAudioRequest(trackId: String) -> (url: URL, headers: [String: String])? {
        guard let token = KeychainStore.read(.accessToken),
              let url = URL(string: baseURL.absoluteString + "/catalog/tracks/\(escaped(trackId))/audio")
        else { return nil }

        return (url, ["Authorization": "Bearer \(token)"])
    }

    /// Whether the current route needs the pinned trust evaluation.
    ///
    /// AVPlayer does its own connecting, so it has to be told when the
    /// certificate will not name the host it is dialling.
    var routeNeedsPinnedTrust: Bool { route.skipsHostnameCheck }

    /// What the probe found, for the diagnostics report.
    func routeReport() async -> [String: Bool] {
        await APIRouter.shared.lastProbeResults
    }

    /// Asks the server to resolve a stream before it is needed.
    ///
    /// Fire and forget: a failure here only means the track starts as slowly
    /// as it would have anyway.
    func warmStream(trackId: String) async {
        _ = try? await send(
            "/catalog/tracks/\(escaped(trackId))/warm", method: "POST"
        ) as MessageResponse
    }

    // MARK: - Wave

    func wave(
        limit: Int = 40,
        mood: String = "all",
        diversity: String = "default",
        seed: String? = nil
    ) async throws -> WaveResponse {
        var path = "/wave?limit=\(limit)&mood=\(mood)&diversity=\(diversity)"
        if let seed {
            path += "&seed=\(escaped(seed))"
        }
        return try await send(path, method: "GET")
    }

    func waveSimilar(trackId: String, limit: Int = 30) async throws -> [CatalogTrackDTO] {
        try await send("/wave/similar/\(escaped(trackId))?limit=\(limit)", method: "GET")
    }

    func homeFeed(limit: Int = 30) async throws -> HomeFeedResponse {
        try await send("/wave/home?limit=\(limit)", method: "GET")
    }

    // MARK: - Transport

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
            (data, response) = try await activeSession.data(for: request)
        } catch {
            // Not reaching the server at all is worth trying elsewhere; an
            // error the server itself returned is not.
            if !isRetry {
                await APIRouter.shared.routeFailed(route)
                let rediscovered = await APIRouter.shared.route

                if rediscovered != route {
                    route = rediscovered
                    return try await perform(
                        path, method: method, bodyData: bodyData,
                        authenticated: authenticated, isRetry: true
                    )
                }
            }
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
