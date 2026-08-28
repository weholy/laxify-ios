import SwiftUI
import SwiftData
import UIKit

struct AppRootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query private var favorites: [FavoriteTrack]
    @Query private var dislikedTracks: [DislikedTrack]

    var session = SessionStore.shared
    var localization = LocalizationManager.shared

    @State private var hasShownWelcome = false

    var body: some View {
        Group {
            if !localization.hasPicked {
                LanguagePickerView()
                    .transition(.opacity)
            } else {
                signedInFlow
            }
        }
        .animation(.easeInOut(duration: 0.35), value: localization.hasPicked)
        .animation(.easeInOut(duration: 0.35), value: session.state)
        .task {
            // Signing out has to be able to clear the on-device library, and
            // only a view has the context to do it with.
            session.modelContext = modelContext
            AudioPlayerController.shared.modelContext = modelContext
            await restore()

            // Anything played while the server was out of reach goes up
            // first, so the history that comes down includes it.
            await PlaybackUploader.flush(context: modelContext)

            // Bring the account's listening history down, so the figures the
            // device works out are the same ones the server would.
            await HistoryMirror.sync(context: modelContext)
        }
        .onChange(of: scenePhase) { _, phase in
            // Coming back to the app is the most likely moment for the
            // network to have changed, and the moment a backlog is worth
            // trying again.
            guard phase == .active else { return }
            Task { await PlaybackUploader.flush(context: modelContext) }
        }
        .onOpenURL { url in
            guard !DeepLinkRouter.shared.handle(url) else { return }
            AuthService.shared.handle(url: url)
        }
    }

    @ViewBuilder
    private var signedInFlow: some View {
        Group {
            switch session.state {
            case .unknown:
                launchScreen

            case .signedOut:
                SignInView(
                    onSignedIn: { user in await signIn(user) },
                    onSignedInWithEmail: { created in await signInWithEmail(created) }
                )
                .transition(.opacity)

            case .needsOnboarding:
                OnboardingView(
                    suggestedName: session.user?.displayName ?? "",
                    suggestedUsername: session.user?.username ?? "",
                    googleAvatarURL: session.user?.avatarURL
                )
                .transition(.opacity)

            case .guest:
                RootView()
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
    private func signInWithEmail(_ created: BackendSessionResponse) async {
        await session.adopt(created)
        await migrateLocalDataIfNeeded()
    }

    /// Sends what this device collected before it had an account at all.
    ///
    /// Only offered when the server says this account has never migrated, and
    /// only when there is genuinely something here. Sending unconditionally is
    /// what put one person's library onto the next person's profile.
    private func migrateLocalDataIfNeeded() async {
        guard session.needsLocalMigration else { return }

        let localFavorites = favorites.map { (song: $0.song, addedAt: $0.addedAt) }
        let localDislikes = dislikedTracks.map(\.id)
        let seconds = ListeningStatsService.shared.totalSecondsListened

        guard LocalStateReset.hasUnmigratedLocalData(
            favorites: localFavorites.count,
            dislikes: localDislikes.count,
            seconds: seconds
        ) else { return }

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
