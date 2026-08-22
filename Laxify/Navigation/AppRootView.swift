import SwiftUI
import SwiftData
import UIKit

struct AppRootView: View {
    @Query private var favorites: [FavoriteTrack]
    @Query private var dislikedTracks: [DislikedTrack]

    var session = SessionStore.shared

    @State private var hasShownWelcome = false

    var body: some View {
        Group {
            switch session.state {
            case .unknown:
                launchScreen

            case .signedOut:
                SignInView(
                    onSignedIn: { user in await signIn(user) },
                    onSignedInWithEmail: { await signInWithEmail() }
                )
                .transition(.opacity)

            case .needsOnboarding:
                OnboardingView(
                    suggestedName: session.user?.displayName ?? "",
                    suggestedUsername: session.user?.username ?? "",
                    googleAvatarURL: session.user?.avatarURL
                )
                .transition(.opacity)

            case .signedIn:
                if hasShownWelcome {
                    RootView()
                        .transition(.opacity)
                } else {
                    WelcomeView(name: session.user?.displayName ?? "") {
                        withAnimation(.easeInOut(duration: 0.35)) {
                            hasShownWelcome = true
                        }
                    }
                    .transition(.opacity)
                }
            }
        }
        .animation(.easeInOut(duration: 0.35), value: session.state)
        .task {
            await restore()
        }
        .onOpenURL { url in
            guard !DeepLinkRouter.shared.handle(url) else { return }
            AuthService.shared.handle(url: url)
        }
    }

    /// Plain background, no mark: this state is normally skipped entirely
    /// because a stored session starts signed-in, and anything drawn for a
    /// frame or two reads as a flash rather than as branding.
    private var launchScreen: some View {
        LaxifyPalette.background
            .ignoresSafeArea()
            .transition(.opacity)
    }

    private func restore() async {
        await session.restore()

        // The backend session outlives Google's, and it is what actually
        // authorises requests — so Google is only consulted when there is no
        // server session left to restore.
        guard session.state == .signedOut else { return }

        // Never block the launch on this: the SDK call can hang on an
        // unreachable network, and the sign-in screen is a recoverable place
        // to land, unlike a screen that never changes.
        let restored = await withTaskGroup(of: AuthenticatedGoogleUser?.self) { group in
            group.addTask { await AuthService.shared.restorePreviousSignIn() }
            group.addTask {
                try? await Task.sleep(for: .seconds(4))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        if let restored, !restored.idToken.isEmpty {
            _ = await session.signIn(idToken: restored.idToken, deviceName: Self.deviceName)
        }
    }

    private func signIn(_ user: AuthenticatedGoogleUser) async {
        guard !user.idToken.isEmpty else { return }
        guard await session.signIn(idToken: user.idToken, deviceName: Self.deviceName) else {
            return
        }
        await migrateLocalDataIfNeeded()
    }

    /// The email flow already holds a session by the time it calls back —
    /// the tokens were stored when the server issued them. All that is left is
    /// to load the account behind them.
    private func signInWithEmail() async {
        await session.restore()
        await migrateLocalDataIfNeeded()
    }

    /// Sends whatever the app collected before this account existed. The
    /// server accepts this once per account and rejects repeats, so there is
    /// no risk of double-counting listening time.
    private func migrateLocalDataIfNeeded() async {
        let localFavorites = favorites.map { (song: $0.song, addedAt: $0.addedAt) }
        let localDislikes = dislikedTracks.map(\.id)
        let seconds = ListeningStatsService.shared.totalSecondsListened

        guard !localFavorites.isEmpty || !localDislikes.isEmpty || seconds > 0 else { return }

        try? await LaxifyAPI.shared.migrateLocalData(
            favorites: localFavorites,
            dislikedTrackIds: localDislikes,
            totalSecondsListened: seconds
        )
    }

    private static var deviceName: String {
        UIDevice.current.name
    }
}

#Preview {
    AppRootView()
}
