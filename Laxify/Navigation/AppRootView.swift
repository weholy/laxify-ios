import SwiftUI
import SwiftData

struct AppRootView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [UserProfile]

    @State private var isRestoring = true
    @State private var hasShownWelcome = false

    private var profile: UserProfile? { profiles.first }

    var body: some View {
        Group {
            if isRestoring {
                launchLoading
            } else if let profile {
                if !profile.hasCompletedOnboarding {
                    OnboardingView(profile: profile, onFinished: {})
                } else if !hasShownWelcome {
                    WelcomeView(name: profile.displayName) {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            hasShownWelcome = true
                        }
                    }
                    .transition(.opacity)
                } else {
                    RootView()
                        .transition(.opacity)
                }
            } else {
                SignInView { user in
                    withAnimation(.easeInOut(duration: 0.4)) {
                        handleSignedIn(user)
                    }
                }
                .transition(.opacity)
            }
        }
        .task {
            await restoreSession()
        }
        .onOpenURL { url in
            guard !DeepLinkRouter.shared.handle(url) else { return }
            AuthService.shared.handle(url: url)
        }
    }

    /// Deliberately just the brand mark, no spinner: the check is usually
    /// instant, and a spinner that appears for two frames reads as a glitch.
    private var launchLoading: some View {
        ZStack {
            LaxifyPalette.background.ignoresSafeArea()

            Image(systemName: "waveform")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(LaxifyPalette.accent)
                .opacity(0.9)
        }
        .transition(.opacity)
    }

    /// Restores a previous session, but never blocks the launch on it.
    ///
    /// The SDK call can hang indefinitely when the network is unreachable or
    /// the token endpoint is slow, which left the app sitting on the launch
    /// mark with no way forward. Racing it against a timeout means the worst
    /// case is landing on the sign-in screen, which is recoverable — unlike a
    /// screen that never changes.
    private func restoreSession() async {
        let restored = await withTaskGroup(of: AuthenticatedGoogleUser?.self) { group in
            group.addTask {
                await AuthService.shared.restorePreviousSignIn()
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(4))
                return nil
            }

            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        if let restored {
            handleSignedIn(restored)
            // Give SwiftData a beat to surface the inserted profile, otherwise
            // the query is still empty when the flag drops and the sign-in
            // screen flashes for a frame.
            try? await Task.sleep(for: .milliseconds(120))
        }

        withAnimation(.easeInOut(duration: 0.35)) {
            isRestoring = false
        }
    }

    private func handleSignedIn(_ user: AuthenticatedGoogleUser) {
        if let existing = profiles.first(where: { $0.googleUserId == user.googleUserId }) {
            existing.email = user.email
            if existing.displayName.isEmpty {
                existing.displayName = user.displayName
            }
            if existing.googleAvatarURLString == nil {
                existing.googleAvatarURLString = user.avatarURLString
            }
        } else {
            let newProfile = UserProfile(
                googleUserId: user.googleUserId,
                email: user.email,
                displayName: user.displayName,
                googleAvatarURLString: user.avatarURLString
            )
            modelContext.insert(newProfile)
        }
    }
}

#Preview {
    AppRootView()
}
