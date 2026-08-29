import Foundation
import SwiftData
import SwiftData

/// The app's view of "who is signed in".
///
/// The server is the source of truth for identity; the local SwiftData copy
/// stays as an offline cache so the UI still renders without a connection.
@MainActor
@Observable
final class SessionStore {
    static let shared = SessionStore()

    enum State: Equatable {
        case unknown
        case signedOut
        case needsOnboarding
        case signedIn
        /// Listening without an account.
        ///
        /// Exists because our server is unreachable on some networks while
        /// the music is not — and an app that is only a sign-in screen is
        /// worse than one that plays. The library stays on the device and
        /// goes up when an account is added.
        case guest
    }

    private(set) var state: State = .unknown
    private(set) var user: BackendUser?
    private(set) var lastError: String?
    private(set) var isBusy = false

    /// Whether the server has said this account has never taken on data from
    /// a device. Only then is there anything worth offering it.
    private(set) var needsLocalMigration = false

    /// Set by the root view so signing out can clear the on-device library.
    var modelContext: ModelContext?

    private static let cacheKey = "laxify.session.user"

    private init() {
        user = Self.loadCachedUser()

        // Start optimistically when a session is already on the device: the
        // launch screen used to sit there until the server answered, which is
        // a visible wait for something that is almost always still valid.
        // `restore()` then confirms it in the background and corrects course
        // only if the server disagrees.
        if KeychainStore.read(.accessToken) != nil, let cached = user {
            state = cached.hasCompletedOnboarding ? .signedIn : .needsOnboarding
        } else if Self.wasGuest {
            state = .guest
        }
    }

    /// The profile is cached so the app can render a name and avatar while
    /// offline; identity still comes from the server whenever it answers.
    private static func loadCachedUser() -> BackendUser? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode(BackendUser.self, from: data)
    }

    private func cache(_ user: BackendUser?) {
        guard let user, let data = try? JSONEncoder().encode(user) else {
            UserDefaults.standard.removeObject(forKey: Self.cacheKey)
            return
        }
        UserDefaults.standard.set(data, forKey: Self.cacheKey)
    }

    /// Restores an existing session on launch.
    ///
    /// Only a definite 401 signs the user out. A network failure leaves the
    /// stored tokens alone and keeps whatever was cached, so a dead connection
    /// does not silently log someone out of their own library.
    /// Adopts a session the email flow already created.
    ///
    /// The tokens are stored by then; what is missing is the profile behind
    /// them and whether this account has ever taken on device data.
    func adopt(_ session: BackendSessionResponse) async {
        needsLocalMigration = session.needsLocalMigration

        guard let user = try? await LaxifyAPI.shared.currentUser() else {
            await restore()
            return
        }

        self.user = user
        cache(user)
        state = session.needsOnboarding ? .needsOnboarding : .signedIn
        await SyncOutbox.shared.flush()
    }

    func restore() async {
        // Someone who chose to listen without an account stays there until
        // they sign in themselves.
        if Self.wasGuest, KeychainStore.read(.accessToken) == nil {
            state = .guest
            return
        }

        guard await LaxifyAPI.shared.isSignedIn else {
            state = .signedOut
            return
        }

        do {
            let user = try await LaxifyAPI.shared.currentUser()
            self.user = user
            cache(user)
            state = user.hasCompletedOnboarding ? .signedIn : .needsOnboarding
            await SyncOutbox.shared.flush()
        } catch APIError.notAuthenticated {
            state = .signedOut
        } catch {
            // Offline: trust the stored session rather than dropping it.
            state = .signedIn
        }
    }

    func signIn(idToken: String, deviceName: String) async -> Bool {
        isBusy = true
        lastError = nil
        defer { isBusy = false }

        do {
            let session = try await LaxifyAPI.shared.signInWithGoogle(
                idToken: idToken, deviceName: deviceName
            )
            let user = try await LaxifyAPI.shared.currentUser()
            self.user = user
            cache(user)
            needsLocalMigration = session.needsLocalMigration
            state = session.needsOnboarding ? .needsOnboarding : .signedIn
            await SyncOutbox.shared.flush()
            return true
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "Не удалось войти"
            AppLogger.log("auth: backend sign-in failed \(error)")
            return false
        }
    }

    func signInWithTelegram(payload: [String: String], deviceName: String) async -> Bool {
        isBusy = true
        lastError = nil
        defer { isBusy = false }

        do {
            let session = try await LaxifyAPI.shared.signInWithTelegram(
                payload: payload, deviceName: deviceName
            )
            let user = try await LaxifyAPI.shared.currentUser()
            self.user = user
            cache(user)
            needsLocalMigration = session.needsLocalMigration
            state = session.needsOnboarding ? .needsOnboarding : .signedIn
            await SyncOutbox.shared.flush()
            return true
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "Не удалось войти"
            AppLogger.log("auth: telegram sign-in failed \(error)")
            return false
        }
    }

    func completeOnboarding(
        displayName: String,
        username: String,
        avatarURL: String?
    ) async -> String? {
        isBusy = true
        defer { isBusy = false }

        do {
            user = try await LaxifyAPI.shared.completeOnboarding(
                displayName: displayName,
                username: username,
                avatarURL: avatarURL
            )
            cache(user)
            state = .signedIn
            return nil
        } catch APIError.server(_, let detail) {
            return detail
        } catch {
            return "Не удалось сохранить профиль"
        }
    }

    /// Saves whatever was passed and leaves the rest alone — the server
    /// treats an omitted field as unchanged, so one call covers the profile
    /// sheet and every individual toggle in settings.
    @discardableResult
    func updateProfile(
        displayName: String? = nil,
        username: String? = nil,
        bio: String? = nil,
        isProfilePublic: Bool? = nil,
        isStatsPublic: Bool? = nil,
        settings: [String: String]? = nil
    ) async -> String? {
        isBusy = true
        defer { isBusy = false }

        do {
            user = try await LaxifyAPI.shared.updateProfile(
                displayName: displayName,
                username: username,
                bio: bio,
                isProfilePublic: isProfilePublic,
                isStatsPublic: isStatsPublic,
                settings: settings
            )
            cache(user)
            return nil
        } catch APIError.server(_, let detail) {
            return detail
        } catch {
            return "Не удалось сохранить изменения"
        }
    }

    func refreshUser() async {
        guard let refreshed = try? await LaxifyAPI.shared.currentUser() else { return }
        user = refreshed
        cache(refreshed)
    }

    /// Continues without an account.
    ///
    /// Remembered, so the choice does not have to be made again on every
    /// launch — but it is only offered when the server cannot be reached at
    /// all, and signing in later keeps everything collected in the meantime.
    func continueAsGuest() {
        UserDefaults.standard.set(true, forKey: Self.guestKey)
        state = .guest
    }

    func leaveGuest() {
        UserDefaults.standard.removeObject(forKey: Self.guestKey)
        state = .signedOut
    }

    private static let guestKey = "laxify.session.guest"

    private static var wasGuest: Bool {
        UserDefaults.standard.bool(forKey: guestKey)
    }

    func signOut() async {
        await LaxifyAPI.shared.signOut()
        AuthService.shared.signOut()

        // Everything this account left on the device goes with it. Without
        // this the next person to sign in inherited the library, the
        // listening time, and the queued changes still waiting to be sent.
        LocalStateReset.performOnSignOut(context: modelContext)

        user = nil
        needsLocalMigration = false
        cache(nil)
        state = .signedOut
    }
}
