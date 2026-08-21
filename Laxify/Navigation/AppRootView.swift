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
                    handleSignedIn(user)
                }
            }
        }
        .task {
            if let user = await AuthService.shared.restorePreviousSignIn() {
                handleSignedIn(user)
            }
            isRestoring = false
        }
        .onOpenURL { url in
            guard !DeepLinkRouter.shared.handle(url) else { return }
            AuthService.shared.handle(url: url)
        }
    }

    private var launchLoading: some View {
        ZStack {
            LaxifyPalette.background.ignoresSafeArea()
            ProgressView()
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
