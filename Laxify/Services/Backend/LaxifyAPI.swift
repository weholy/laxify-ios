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
        // Long enough for a cold home feed, which assembles several upstream
        // calls, but not so long that an unreachable server holds up
        // everything queued behind it.
        configuration.timeoutIntervalForRequest = 20
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

    /// Whether any route to the server answered the last time it was
    /// checked.
    ///
    /// Callers that have a way to work without us — search, the home feed —
    /// consult this before spending a timeout on a server that is known to
    /// be unreachable.
    var isServerReachable: Bool {
        get async {
            let results = await APIRouter.shared.lastProbeResults
            // Nothing checked yet: assume reachable rather than write the
            // server off before it has been tried.
            guard !results.isEmpty else { return true }
            return results.values.contains(true)
        }
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

    /// `payload` is the raw Telegram Login Widget field set (hash included),
    /// exactly as the widget produced it — the server re-checks the signature.
    func signInWithTelegram(payload: [String: String], deviceName: String) async throws -> BackendSessionResponse {
        struct Body: Encodable {
            let payload: [String: String]
            let device: Device
            struct Device: Encodable {
                let name: String
                let model: String?
                let appVersion: String?
            }
        }

        let body = Body(
            payload: payload,
            device: .init(
                name: deviceName,
                model: nil,
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            )
        )

        let response: BackendSessionResponse = try await send(
            "/auth/telegram", method: "POST", body: body, authenticated: false
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

    /// Revokes every device's session, this one included.
    @discardableResult
    func signOutEverywhere() async throws -> MessageResponse {
        try await send("/auth/logout-all", method: "POST")
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
        avatarUrl: String? = nil,
        isProfilePublic: Bool? = nil,
        isStatsPublic: Bool? = nil,
        settings: [String: String]? = nil
    ) async throws -> BackendUser {
        struct Body: Encodable {
            let displayName: String?
            let username: String?
            let bio: String?
            let avatarUrl: String?
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
                avatarUrl: avatarUrl,
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

    /// Sends the artist list the app collected.
    ///
    /// It decides which accounts are shown, and it can only be gathered from
    /// a device — the catalogue it comes from does not answer our server at
    /// all.
    @discardableResult
    func uploadReference(
        _ artists: [ReferenceArtistUpload], replace: Bool
    ) async throws -> ReferenceUploadResult {
        struct Body: Encodable {
            let artists: [ReferenceArtistUpload]
            let replace: Bool
        }
        return try await send(
            "/catalog/reference",
            method: "POST",
            body: Body(artists: artists, replace: replace)
        )
    }

    // MARK: - Playlists

    func myPlaylists() async throws -> [PlaylistDTO] {
        let page: BackendPage<PlaylistDTO> = try await send("/playlists?limit=200", method: "GET")
        return page.items
    }

    func playlist(id: String) async throws -> PlaylistDetailDTO {
        try await send("/playlists/\(escaped(id))", method: "GET")
    }

    func createPlaylist(
        title: String, isPublic: Bool, tracks: [BackendTrack] = []
    ) async throws -> PlaylistDetailDTO {
        struct Body: Encodable {
            let title: String
            let isPublic: Bool
            let tracks: [BackendTrack]
        }
        return try await send(
            "/playlists", method: "POST",
            body: Body(title: title, isPublic: isPublic, tracks: tracks)
        )
    }

    /// Only the title — a PATCH that also carried nil fields would blank the
    /// description and cover, since the server treats a present null as "set".
    func renamePlaylist(id: String, title: String) async throws -> PlaylistDTO {
        struct Body: Encodable { let title: String }
        return try await send("/playlists/\(escaped(id))", method: "PATCH", body: Body(title: title))
    }

    func setPlaylistPublic(id: String, isPublic: Bool) async throws -> PlaylistDTO {
        struct Body: Encodable { let isPublic: Bool }
        return try await send("/playlists/\(escaped(id))", method: "PATCH", body: Body(isPublic: isPublic))
    }

    func deletePlaylist(id: String) async throws {
        _ = try await send("/playlists/\(escaped(id))", method: "DELETE") as MessageResponse
    }

    func addTracks(playlistId: String, tracks: [BackendTrack]) async throws {
        struct Body: Encodable { let tracks: [BackendTrack] }
        _ = try await send(
            "/playlists/\(escaped(playlistId))/tracks", method: "POST", body: Body(tracks: tracks)
        ) as MessageResponse
    }

    func removeTrack(playlistId: String, trackId: String) async throws {
        _ = try await send(
            "/playlists/\(escaped(playlistId))/tracks/\(escaped(trackId))", method: "DELETE"
        ) as MessageResponse
    }

    // MARK: - Listening statistics

    /// Minutes this device is ahead of UTC.
    ///
    /// A month has to start at midnight where the listener is; the server
    /// cannot know that on its own.
    private var timeZoneOffset: Int {
        TimeZone.current.secondsFromGMT() / 60
    }

    func replayPeriods() async throws -> [ReplayPeriod] {
        try await send("/replay/periods?tz_offset=\(timeZoneOffset)", method: "GET")
    }

    /// The account's play log, so the device can hold the same history.
    func playHistory(limit: Int = 1000) async throws -> [PlayHistoryEntry] {
        try await send("/replay/history?limit=\(limit)", method: "GET")
    }

    /// Everything the statistics screen opens with, in one round trip.
    func replayBundle() async throws -> ReplayBundle {
        try await send("/replay/bundle?tz_offset=\(timeZoneOffset)", method: "GET")
    }

    func replay(period: String) async throws -> ReplaySummary {
        try await send(
            "/replay?period=\(escaped(period))&limit=10&tz_offset=\(timeZoneOffset)",
            method: "GET"
        )
    }

    /// The key the app uses to reach the source directly.
    ///
    /// Unauthenticated on purpose: the case this exists for is a network
    /// where we are unreachable and the source is not.
    func sourceKey() async throws -> String {
        struct Response: Decodable { let clientId: String }
        let response: Response = try await send(
            "/catalog/source-key", method: "GET", authenticated: false
        )
        return response.clientId
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

    private struct WaveSettingsBody: Encodable {
        let moodEnergy: String
        let diversity: String
        let language: String
        let activity: String

        init(_ s: WaveSettings) {
            moodEnergy = s.mood.rawValue
            diversity = s.diversity.rawValue
            language = s.language.apiValue
            activity = s.activity.rawValue
        }
    }

    /// Opens a wave session and returns the first batch. The `sessionId` it
    /// hands back is what the rest of the wave calls key off.
    func waveStart(settings: WaveSettings) async throws -> WaveSessionDTO {
        struct Body: Encodable { let settings: WaveSettingsBody }
        return try await send(
            "/wave/start", method: "POST", body: Body(settings: WaveSettingsBody(settings))
        )
    }

    /// Advances the chain. `lastTrackId` is the track the listener just left —
    /// everything up to it is consumed and the buffer tops back up.
    func waveNext(sessionId: String, lastTrackId: String?) async throws -> WaveSessionDTO {
        struct Body: Encodable { let sessionId: String; let lastTrackId: String? }
        return try await send(
            "/wave/next", method: "POST",
            body: Body(sessionId: sessionId, lastTrackId: lastTrackId)
        )
    }

    /// trackStarted / trackFinished / skip / like / dislike.
    func waveFeedback(
        sessionId: String,
        type: String,
        trackId: String?,
        playedSeconds: Double? = nil,
        durationSeconds: Double? = nil
    ) async throws {
        struct Body: Encodable {
            let sessionId: String
            let type: String
            let trackId: String?
            let playedSeconds: Double?
            let durationSeconds: Double?
        }
        _ = try await send(
            "/wave/feedback", method: "POST",
            body: Body(
                sessionId: sessionId, type: type, trackId: trackId,
                playedSeconds: playedSeconds, durationSeconds: durationSeconds
            )
        ) as WaveFeedbackDTO
    }

    /// Changes mood/diversity/language/activity mid-stream; the server keeps
    /// whatever is playing and reshapes the tail.
    func waveApplySettings(sessionId: String, settings: WaveSettings) async throws -> WaveSessionDTO {
        struct Body: Encodable {
            let sessionId: String
            let moodEnergy: String
            let diversity: String
            let language: String
            let activity: String
        }
        return try await send(
            "/wave/settings", method: "POST",
            body: Body(
                sessionId: sessionId,
                moodEnergy: settings.mood.rawValue,
                diversity: settings.diversity.rawValue,
                language: settings.language.apiValue,
                activity: settings.activity.rawValue
            )
        )
    }

    /// One-shot stateless wave — home-screen preview and old builds.
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

    /// The Yandex-style home feed: Плейлист дня, Дежавю, Премьера, Тайник…
    func waveFeed() async throws -> WaveFeedDTO {
        try await send("/wave/feed", method: "GET")
    }

    func homeFeed(limit: Int = 30) async throws -> HomeFeedResponse {
        try await send("/wave/home?limit=\(limit)", method: "GET")
    }

    // MARK: - Discover

    /// The genres worth browsing, titled in the app's language by the server.
    func discoverGenres() async throws -> [DiscoverGenre] {
        try await send("/discover/genres", method: "GET")
    }

    /// Popular tracks in one genre, ranked by plays. Limit-only upstream, so
    /// deeper pages of a category come from paged search on the genre name.
    func discoverGenreTracks(genre: String, limit: Int = 60) async throws -> [CatalogTrackDTO] {
        try await send("/discover/genres/\(escaped(genre))/tracks?limit=\(limit)", method: "GET")
    }

    /// Completions for a half-typed query, so the field can suggest rather
    /// than search on every keystroke.
    func discoverSuggest(query: String, limit: Int = 8) async throws -> [String] {
        struct Response: Decodable { let queries: [String] }
        let response: Response = try await send(
            "/discover/suggest?q=\(escaped(query))&limit=\(limit)", method: "GET"
        )
        return response.queries
    }

    // MARK: - Notifications

    struct NotificationDTO: Decodable, Sendable {
        let id: String
        let kind: String
        let title: String
        let body: String
        let actorAvatarUrl: String?
        let actorUsername: String?
        var iconUrl: String?
        let payload: [String: String]?
        let isRead: Bool
        let createdAt: Date
    }

    func notifications(limit: Int = 40, offset: Int = 0) async throws -> [NotificationDTO] {
        try await send("/notifications?limit=\(limit)&offset=\(offset)", method: "GET")
    }

    func notificationsUnreadCount() async throws -> Int {
        struct R: Decodable { let count: Int }
        let r: R = try await send("/notifications/unread-count", method: "GET")
        return r.count
    }

    func markNotificationsRead() async throws {
        let _: MessageResponse = try await send("/notifications/read", method: "POST")
    }

    // MARK: - Admin

    /// One account, as the panel needs to see it.
    ///
    /// Every field the older server does not send yet is optional, so the
    /// panel degrades to a list of names instead of failing to decode — the
    /// deployed build predates this endpoint's wider shape.
    struct AdminUserDTO: Codable, Sendable, Identifiable {
        let id: String
        let username: String
        let displayName: String
        var email: String?
        var avatarUrl: String?
        var googleAvatarUrl: String?
        var isBanned: Bool = false
        var banReason: String?
        var isAdmin: Bool = false
        let createdAt: Date
        var lastSeenAt: Date?

        var avatarURL: URL? {
            if let avatarUrl, let url = URL(string: avatarUrl) { return url }
            if let googleAvatarUrl, let url = URL(string: googleAvatarUrl) { return url }
            return nil
        }
    }

    struct AdminOverviewDTO: Decodable, Sendable {
        var usersTotal: Int = 0
        var usersActive7d: Int = 0
        var playlistsTotal: Int = 0
        var favoritesTotal: Int = 0
        var plays24h: Int = 0
    }

    func adminOverview() async throws -> AdminOverviewDTO {
        try await send("/admin/overview", method: "GET")
    }

    func adminUsers(query: String? = nil, limit: Int = 100, offset: Int = 0) async throws -> [AdminUserDTO] {
        var path = "/admin/users?limit=\(limit)&offset=\(offset)"
        if let query, !query.isEmpty {
            path += "&q=\(escaped(query))"
        }
        let page: BackendPage<AdminUserDTO> = try await send(path, method: "GET")
        return page.items
    }

    func adminBan(userId: String, reason: String) async throws {
        struct Body: Encodable { let reason: String }
        let _: MessageResponse = try await send(
            "/admin/users/\(escaped(userId))/ban", method: "POST", body: Body(reason: reason)
        )
    }

    func adminUnban(userId: String) async throws {
        let _: MessageResponse = try await send(
            "/admin/users/\(escaped(userId))/unban", method: "POST"
        )
    }

    func adminNotify(userId: String, title: String, body message: String, iconUrl: String? = nil) async throws {
        struct Body: Encodable { let title: String; let body: String; let iconUrl: String? }
        let _: MessageResponse = try await send(
            "/admin/users/\(escaped(userId))/notify",
            method: "POST",
            body: Body(title: title, body: message, iconUrl: iconUrl)
        )
    }

    /// One person, counted — every figure the panel shows on a user.
    struct AdminUserStatsDTO: Decodable, Sendable {
        var favorites = 0
        var disliked = 0
        var playlists = 0
        var playlistTracks = 0
        var playsTotal = 0
        var plays7d = 0
        var plays24h = 0
        var minutesTotal = 0
        var distinctTracks = 0
        var distinctArtists = 0
        var completedPlays = 0
        var devices = 0
        var followers = 0
        var following = 0
        var comments = 0
        var searches = 0
        var downloads = 0
        var notifications = 0
        var unreadNotifications = 0
        var daysWithMusic = 0
        var firstPlayAt: Date?
        var lastPlayAt: Date?
        var topArtist: String?
        var topTrack: String?
    }

    struct AdminDayCount: Decodable, Sendable, Identifiable {
        let day: String
        let count: Int
        var id: String { day }
    }

    struct AdminNamedCount: Decodable, Sendable, Identifiable {
        let name: String
        let count: Int
        var id: String { name }
    }

    /// The whole service, counted.
    struct AdminStatsDTO: Decodable, Sendable {
        var usersTotal = 0
        var usersToday = 0
        var users7d = 0
        var users30d = 0
        var usersActive24h = 0
        var usersActive7d = 0
        var usersBanned = 0
        var usersAdmin = 0
        var usersWithAvatar = 0
        var usersNeverPlayed = 0
        var playsTotal = 0
        var plays24h = 0
        var plays7d = 0
        var minutesTotal = 0
        var distinctTracks = 0
        var distinctArtists = 0
        var favoritesTotal = 0
        var playlistsTotal = 0
        var commentsTotal = 0
        var notificationsTotal = 0
        var devicesTotal = 0
        var downloadsTotal = 0
        var tokensActive = 0
        var tokensDisabled = 0
        var signupsByDay: [AdminDayCount] = []
        var playsByDay: [AdminDayCount] = []
        var topTracks: [AdminNamedCount] = []
        var topArtists: [AdminNamedCount] = []
    }

    struct PlaylistImportDTO: Decodable, Sendable {
        let playlistId: String
        let title: String
        let source: String
        let total: Int
        let matched: Int
    }

    /// Builds one of our playlists out of a link to somebody else's.
    ///
    /// Slow by nature — every track is looked up in the catalogue one at a
    /// time — so callers should show that something is happening rather than
    /// assume this returns quickly.
    func importPlaylist(url: String, title: String?) async throws -> PlaylistImportDTO {
        struct Body: Encodable { let url: String; let title: String? }
        return try await send(
            "/playlists/import", method: "POST", body: Body(url: url, title: title)
        )
    }

    func adminStats() async throws -> AdminStatsDTO {
        try await send("/admin/stats", method: "GET")
    }

    func adminUserStats(userId: String) async throws -> AdminUserStatsDTO {
        try await send("/admin/users/\(escaped(userId))/stats", method: "GET")
    }

    func adminBroadcast(
        title: String, body message: String, onlyActive: Bool, iconUrl: String? = nil
    ) async throws -> String {
        struct Body: Encodable {
            let title: String; let body: String; let onlyActive: Bool; let iconUrl: String?
        }
        let response: MessageResponse = try await send(
            "/admin/broadcast",
            method: "POST",
            body: Body(title: title, body: message, onlyActive: onlyActive, iconUrl: iconUrl)
        )
        return response.detail
    }

    func adminSetAdmin(userId: String, isAdmin: Bool) async throws {
        struct Body: Encodable { let isAdmin: Bool }
        let _: MessageResponse = try await send(
            "/admin/users/\(escaped(userId))/admin", method: "POST", body: Body(isAdmin: isAdmin)
        )
    }

    func adminDeleteUser(userId: String) async throws {
        let _: MessageResponse = try await send(
            "/admin/users/\(escaped(userId))", method: "DELETE"
        )
    }

    struct AdminPlayRow: Decodable, Sendable, Identifiable {
        let trackId: String
        let title: String
        let artistName: String
        let playedAt: Date
        var secondsPlayed: Double = 0
        var completed = false

        var id: String { trackId + playedAt.description }
    }

    struct AdminDeviceRow: Decodable, Sendable, Identifiable {
        let name: String
        var model: String?
        var appVersion: String?
        let createdAt: Date
        var lastSeenAt: Date?
        var revoked = false

        var id: String { name + createdAt.description }
    }

    struct AdminActivityDTO: Decodable, Sendable {
        var recentPlays: [AdminPlayRow] = []
        var favorites: [AdminPlayRow] = []
        var devices: [AdminDeviceRow] = []
        var searches: [String] = []
    }

    struct AdminLogRow: Decodable, Sendable, Identifiable {
        let id: String
        var actor: String?
        let action: String
        var targetId: String?
        let createdAt: Date
    }

    func adminActivity(userId: String) async throws -> AdminActivityDTO {
        try await send("/admin/users/\(escaped(userId))/activity", method: "GET")
    }

    func adminLogoutEverywhere(userId: String) async throws -> String {
        let response: MessageResponse = try await send(
            "/admin/users/\(escaped(userId))/logout", method: "POST"
        )
        return response.detail
    }

    func adminClearHistory(userId: String) async throws -> String {
        let response: MessageResponse = try await send(
            "/admin/users/\(escaped(userId))/history", method: "DELETE"
        )
        return response.detail
    }

    func adminLog(limit: Int = 100) async throws -> [AdminLogRow] {
        try await send("/admin/log?limit=\(limit)", method: "GET")
    }

    // MARK: - Diagnostics feed

    /// One line from `RemoteLog`/`CrashReporter`, as the operator reads it —
    /// what happened, on whose phone, and how long it took when that matters.
    struct AdminDiagnosticRow: Decodable, Sendable, Identifiable {
        let id: String
        let sessionId: String
        let level: String
        let category: String
        let message: String
        var durationMs: Int?
        var context: [String: String] = [:]
        var appVersion: String?
        var deviceModel: String?
        let happenedAt: Date
    }

    /// Filtered, paginated read of every line the app has ever phoned home
    /// with — the answer to "make every error visible to you". `nil`
    /// filters mean "any".
    func adminDiagnostics(
        category: String? = nil,
        level: String? = nil,
        sessionId: String? = nil,
        limit: Int = 100,
        offset: Int = 0
    ) async throws -> [AdminDiagnosticRow] {
        var path = "/admin/logs?limit=\(limit)&offset=\(offset)"
        if let category { path += "&category=\(escaped(category))" }
        if let level { path += "&level=\(escaped(level))" }
        if let sessionId { path += "&session_id=\(escaped(sessionId))" }
        let page: BackendPage<AdminDiagnosticRow> = try await send(path, method: "GET")
        return page.items
    }

    struct AdminTimingRow: Decodable, Sendable, Identifiable {
        let message: String
        let samples: Int
        let medianMs: Int
        let p90Ms: Int
        let worstMs: Int
        var id: String { message }
    }

    /// The slow steps, ranked — a median next to a ninetieth percentile says
    /// whether something is slow for everyone or slow occasionally.
    func adminTimings(category: String = "playback", limit: Int = 20) async throws -> [AdminTimingRow] {
        try await send(
            "/admin/logs/timings?category=\(escaped(category))&limit=\(limit)", method: "GET"
        )
    }

    // MARK: - App config (force update)

    struct AppConfigDTO: Decodable, Sendable {
        var minSupportedVersion: String = ""
    }

    /// Unauthenticated on purpose — this is asked before anything else,
    /// including before a sign-in attempt.
    func appConfig() async throws -> AppConfigDTO {
        try await send("/app/config", method: "GET", authenticated: false)
    }

    func adminReadMinVersion() async throws -> String {
        struct Out: Decodable { let minSupportedVersion: String }
        let out: Out = try await send("/admin/config", method: "GET")
        return out.minSupportedVersion
    }

    @discardableResult
    func adminSetMinVersion(_ version: String) async throws -> String {
        struct Body: Encodable { let minSupportedVersion: String }
        struct Out: Decodable { let minSupportedVersion: String }
        let out: Out = try await send(
            "/admin/config", method: "PUT", body: Body(minSupportedVersion: version)
        )
        return out.minSupportedVersion
    }

    // MARK: Profile likes & linked accounts

    struct ProfileLikeDTO: Decodable, Sendable {
        let likedByMe: Bool
        let likeCount: Int?
    }

    func profileLikes(userId: String) async throws -> ProfileLikeDTO {
        try await send("/users/\(escaped(userId))/likes", method: "GET")
    }

    @discardableResult
    func likeProfile(userId: String) async throws -> ProfileLikeDTO {
        try await send("/users/\(escaped(userId))/like", method: "POST")
    }

    @discardableResult
    func unlikeProfile(userId: String) async throws -> ProfileLikeDTO {
        try await send("/users/\(escaped(userId))/like", method: "DELETE")
    }

    func setHideProfileLikes(_ hidden: Bool) async throws {
        let _: MessageResponse = try await send(
            "/users/me/hide-likes?hidden=\(hidden)", method: "POST"
        )
    }

    struct LinkedMethodsDTO: Decodable, Sendable {
        let primary: String
        let googleLinked: Bool
        let telegramLinked: Bool
        let emailLinked: Bool
    }

    func linkedMethods() async throws -> LinkedMethodsDTO {
        try await send("/auth/linked", method: "GET")
    }

    @discardableResult
    func linkGoogle(idToken: String) async throws -> LinkedMethodsDTO {
        struct Body: Encodable { let idToken: String }
        return try await send("/auth/link/google", method: "POST", body: Body(idToken: idToken))
    }

    @discardableResult
    func linkTelegram(payload: [String: String]) async throws -> LinkedMethodsDTO {
        struct Body: Encodable { let payload: [String: String] }
        return try await send("/auth/link/telegram", method: "POST", body: Body(payload: payload))
    }

    @discardableResult
    func unlink(provider: String) async throws -> LinkedMethodsDTO {
        try await send("/auth/unlink/\(provider)", method: "POST")
    }

    struct MediaUploadDTO: Decodable, Sendable { let url: String }

    /// A photo/clip for a comment, or a new avatar. Multipart, so it builds
    /// its own request rather than going through `perform`. The server
    /// forwards it to Catbox and returns the URL.
    func uploadMedia(_ data: Data, filename: String, mimeType: String) async throws -> URL {
        guard let token = KeychainStore.read(.accessToken) else { throw APIError.notAuthenticated }
        guard let url = URL(string: baseURL.absoluteString + "/media/upload") else {
            throw APIError.server(status: 0, detail: "Некорректный адрес запроса")
        }

        let boundary = "laxify-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append(
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n"
                .data(using: .utf8)!
        )
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = body

        let (respData, response) = try await activeSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.server(
                status: (response as? HTTPURLResponse)?.statusCode ?? 0,
                detail: "Не удалось загрузить файл"
            )
        }
        let dto = try decoder.decode(MediaUploadDTO.self, from: respData)
        guard let out = URL(string: dto.url) else {
            throw APIError.server(status: 0, detail: "Пустой ответ")
        }
        return out
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
