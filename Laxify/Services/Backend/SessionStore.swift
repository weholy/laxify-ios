import Foundation
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
    }

    private(set) var state: State = .unknown
    private(set) var user: BackendUser?
    private(set) var lastError: String?
    private(set) var isBusy = false

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
    func restore() async {
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
            state = session.needsOnboarding ? .needsOnboarding : .signedIn
            await SyncOutbox.shared.flush()
            return true
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "Не удалось войти"
            AppLogger.log("auth: backend sign-in failed \(error)")
            return false
        }
    }

    func completeOnboarding(
        displayName: String,
        username: String,
        birthdate: Date?,
        avatarURL: String?
    ) async -> String? {
        isBusy = true
        defer { isBusy = false }

        do {
            user = try await LaxifyAPI.shared.completeOnboarding(
                displayName: displayName,
                username: username,
                birthdate: birthdate,
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

    func signOut() async {
        await LaxifyAPI.shared.signOut()
        AuthService.shared.signOut()
        user = nil
        cache(nil)
        state = .signedOut
    }
}
