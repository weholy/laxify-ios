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

    /// Set when the server has said this account is blocked, with the reason
    /// it gave. The root view shows it as an alert and clears it when read.
    var blockedReason: String?

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

        let fetched: BackendUser
        do {
            fetched = try await LaxifyAPI.shared.currentUser()
        } catch APIError.accountBlocked(let reason) {
            accountBlocked(reason: reason)
            return
        } catch {
            await restore()
            return
        }

        let user = fetched
        LocalStateReset.prepareForAccount(user.id, previouslyCached: self.user?.id, context: modelContext)
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
            // No tokens, but a profile still cached: an account ended while
            // the app was away. Its data goes with it — landing on the
            // sign-in screen with the library still here is how the next
            // account came to inherit it.
            if user != nil { finishLocalSignOut() } else { state = .signedOut }
            return
        }

        do {
            let user = try await LaxifyAPI.shared.currentUser()
            LocalStateReset.prepareForAccount(user.id, previouslyCached: self.user?.id, context: modelContext)
            self.user = user
            cache(user)
            state = user.hasCompletedOnboarding ? .signedIn : .needsOnboarding
            await claimOwnerHandle()
            await SyncOutbox.shared.flush()
        } catch APIError.notAuthenticated {
            // The server ended this session — expired, revoked from another
            // device, or the account removed. Same as signing out: this used
            // to only flip the screen, and everything stayed behind.
            finishLocalSignOut()
        } catch APIError.accountBlocked(let reason) {
            accountBlocked(reason: reason)
        } catch {
            // Offline: trust the stored session rather than dropping it.
            state = .signedIn
        }
    }

    /// The server has refused this account outright.
    ///
    /// Signs out locally — the tokens are no use any more — and leaves the
    /// reason for the root view to put in front of the person, instead of
    /// quietly dropping them at the sign-in screen to wonder why.
    func accountBlocked(reason: String) {
        let text = reason.isEmpty ? "Аккаунт заблокирован" : reason
        // The same refusal can arrive twice — from the request that hit it,
        // and from the caller that made that request.
        if state == .signedOut, blockedReason == text { return }

        blockedReason = text
        KeychainStore.clear()
        finishLocalSignOut()
    }

    /// The server has ended the session some other way than the sign-out
    /// button. Reached from any request, not only at launch.
    func sessionEnded() {
        guard state == .signedIn || state == .needsOnboarding else { return }
        finishLocalSignOut()
    }

    /// Everything a sign-out means on this device, whichever way it came.
    private func finishLocalSignOut() {
        AuthService.shared.signOut()
        LocalStateReset.performOnSignOut(context: modelContext)

        user = nil
        needsLocalMigration = false
        cache(nil)
        state = .signedOut
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
            LocalStateReset.prepareForAccount(user.id, previouslyCached: self.user?.id, context: modelContext)
            self.user = user
            cache(user)
            needsLocalMigration = session.needsLocalMigration
            state = session.needsOnboarding ? .needsOnboarding : .signedIn
            await SyncOutbox.shared.flush()
            return true
        } catch APIError.accountBlocked(let reason) {
            // Shown as the system alert, not as a line of red text under the
            // button — a blocked account is not a sign-in that went wrong.
            accountBlocked(reason: reason)
            return false
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
            LocalStateReset.prepareForAccount(user.id, previouslyCached: self.user?.id, context: modelContext)
            self.user = user
            cache(user)
            needsLocalMigration = session.needsLocalMigration
            state = session.needsOnboarding ? .needsOnboarding : .signedIn
            await SyncOutbox.shared.flush()
            return true
        } catch APIError.accountBlocked(let reason) {
            accountBlocked(reason: reason)
            return false
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
        avatarURL: String? = nil,
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
                avatarUrl: avatarURL,
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

    /// The account this app is built by answers to one handle.
    ///
    /// Tried once per restore and given up on quietly: if the name is already
    /// taken by someone else the server refuses, and there is nothing useful
    /// to say about that on a launch screen.
    private func claimOwnerHandle() async {
        guard let user, user.email.lowercased() == Self.ownerEmail else { return }
        guard user.username.lowercased() != Self.ownerHandle else { return }

        _ = await updateProfile(username: Self.ownerHandle)
    }

    private static let ownerEmail = "amondimitry@gmail.com"
    private static let ownerHandle = "skyredy"

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

        // Everything this account left on the device goes with it. Without
        // this the next person to sign in inherited the library, the
        // listening time, and the queued changes still waiting to be sent.
        finishLocalSignOut()
    }
}
