import Foundation
import UIKit
@preconcurrency import GoogleSignIn

struct AuthenticatedGoogleUser: Sendable {
    let googleUserId: String
    let email: String
    let displayName: String
    let avatarURLString: String?
    /// Google's signed assertion of who this is. The backend verifies it
    /// against Google's public keys — the other fields here are convenience
    /// only and are never trusted server-side.
    let idToken: String
}

enum AuthError: Error {
    case missingPresenter
    case missingProfile
    case cancelled
    case underlying(Error)
}

@MainActor
@Observable
final class AuthService {
    static let shared = AuthService()

    private init() {}

    func restorePreviousSignIn() async -> AuthenticatedGoogleUser? {
        await withCheckedContinuation { continuation in
            GIDSignIn.sharedInstance.restorePreviousSignIn { user, error in
                guard let user, error == nil else {
                    continuation.resume(returning: nil)
                    return
                }
                // A restored session often carries an expired ID token, which
                // the backend would reject; refreshing first avoids that.
                user.refreshTokensIfNeeded { refreshed, _ in
                    continuation.resume(returning: Self.map(refreshed ?? user))
                }
            }
        }
    }

    func signIn() async throws -> AuthenticatedGoogleUser {
        guard let presenter = Self.topViewController() else {
            throw AuthError.missingPresenter
        }

        return try await withCheckedThrowingContinuation { continuation in
            GIDSignIn.sharedInstance.signIn(withPresenting: presenter) { result, error in
                if let error {
                    if let signInError = error as? GIDSignInError, signInError.code == .canceled {
                        continuation.resume(throwing: AuthError.cancelled)
                    } else {
                        continuation.resume(throwing: AuthError.underlying(error))
                    }
                    return
                }
                guard let user = result?.user else {
                    continuation.resume(throwing: AuthError.missingProfile)
                    return
                }
                continuation.resume(returning: Self.map(user))
            }
        }
    }

    func signOut() {
        GIDSignIn.sharedInstance.signOut()
    }

    func handle(url: URL) {
        GIDSignIn.sharedInstance.handle(url)
    }

    private static func map(_ user: GIDGoogleUser) -> AuthenticatedGoogleUser {
        AuthenticatedGoogleUser(
            googleUserId: user.userID ?? UUID().uuidString,
            email: user.profile?.email ?? "",
            displayName: user.profile?.name ?? "",
            avatarURLString: user.profile?.imageURL(withDimension: 200)?.absoluteString,
            idToken: user.idToken?.tokenString ?? ""
        )
    }

    private static func topViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
            let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            return nil
        }
        var top = root
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }
}
