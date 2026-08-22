import SwiftUI

struct SignInView: View {
    var onSignedIn: (AuthenticatedGoogleUser) async -> Void
    /// Called when a session was created without Google. The response comes
    /// with it, so the caller knows whether this account is new enough to be
    /// offered whatever the device collected before it existed.
    var onSignedInWithEmail: (BackendSessionResponse) async -> Void

    @State private var isSigningIn = false
    @State private var errorMessage: String?
    @State private var appear = false
    @State private var buttonAppear = false
    @State private var coverSongs: [Song] = CoverArtCache.load()
    @State private var showsEmailSignIn = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            bottomPanel
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(alignment: .top) {
            driftingArtwork
        }
        .background(LaxifyPalette.background.ignoresSafeArea())
        .task {
            await loadCovers()
        }
        .fullScreenCover(isPresented: $showsEmailSignIn) {
            EmailSignInView(
                onSignedIn: { created in
                    showsEmailSignIn = false
                    await onSignedInWithEmail(created)
                },
                onCancel: { showsEmailSignIn = false }
            )
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.7).delay(0.15)) {
                appear = true
            }
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.45)) {
                buttonAppear = true
            }
        }
    }

    /// The artwork wall is masked so it dissolves into the background at both
    /// ends: sharp in the middle, gone behind the sign-in panel.
    private var driftingArtwork: some View {
        ZStack {
            PlaceholderCoversView()
                .opacity(coverSongs.isEmpty ? 1 : 0)

            if !coverSongs.isEmpty {
                FloatingCoversView(songs: coverSongs)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .clipped()
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .white, location: 0.18),
                    .init(color: .white, location: 0.45),
                    .init(color: .clear, location: 0.62)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }

    private var bottomPanel: some View {
        VStack(spacing: 0) {

            Text("Вся твоя музыка\nв одном месте")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(LaxifyPalette.textPrimary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.bottom, 28)

            VStack(spacing: 12) {
                googleButton
                emailButton
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)
            .opacity(buttonAppear ? 1 : 0)
            .offset(y: buttonAppear ? 0 : 24)
            .scaleEffect(buttonAppear ? 1 : 0.96)

            if let errorMessage {
                Text(errorMessage)
                    .font(LaxifyTypography.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.top, 12)
                    .padding(.horizontal, LaxifyMetrics.screenPadding)
                    .transition(.opacity)
            }

            Text("Продолжая, вы принимаете условия использования")
                .font(.system(size: 11))
                .foregroundStyle(LaxifyPalette.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.top, 14)
                .padding(.horizontal, 32)
        }
        .padding(.bottom, 28)
        .opacity(appear ? 1 : 0)
        .offset(y: appear ? 0 : 20)
    }


    /// The way in that does not depend on Google being reachable.
    private var emailButton: some View {
        Button {
            showsEmailSignIn = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "envelope.fill")
                    .font(.system(size: 16, weight: .semibold))
                Text("Войти по почте")
                    .font(.system(size: 17, weight: .semibold))
            }
            .foregroundStyle(LaxifyPalette.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 17)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .disabled(isSigningIn)
    }

    private var googleButton: some View {
        Button {
            signIn()
        } label: {
            HStack(spacing: 10) {
                if isSigningIn {
                    ProgressView()
                        .tint(LaxifyPalette.background)
                } else {
                    GoogleLogoView(size: 20)
                }

                Text(isSigningIn ? "Входим…" : "Продолжить с Google")
                    .font(.system(size: 17, weight: .semibold))
            }
            .foregroundStyle(LaxifyPalette.background)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 17)
            .background(LaxifyPalette.textPrimary, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isSigningIn)
    }

    private func signIn() {
        withAnimation { errorMessage = nil }
        isSigningIn = true
        Task {
            do {
                let user = try await AuthService.shared.signIn()
                await onSignedIn(user)
                isSigningIn = false
            } catch AuthError.cancelled {
                isSigningIn = false
            } catch {
                isSigningIn = false
                withAnimation {
                    errorMessage = "Не удалось войти. Попробуйте ещё раз"
                }
                AppLogger.log("auth: sign-in failed \(error)")
            }
        }
    }

    /// Fills the wall with real artwork.
    ///
    /// Searching needs a session, and this is the one screen where nobody has
    /// one — which is why the wall was coloured squares. The server offers
    /// what is popular without asking for a token.
    ///
    /// Cached covers are already on screen, so a failure here changes nothing
    /// visible.
    private func loadCovers() async {
        guard let showcase = try? await LaxifyAPI.shared.showcase(limit: 40) else {
            AppLogger.log("signin: showcase unavailable, keeping what is shown")
            return
        }

        let songs = showcase.map(\.song).filter { $0.coverURL != nil }
        guard songs.count >= 6 else { return }

        let fresh = songs.shuffled()

        // Fetched before they are shown, so the wall fades in whole rather
        // than filling in square by square.
        AsyncCoverImage.prefetchCovers(for: Array(fresh.prefix(20)), width: 110)
        try? await Task.sleep(for: .milliseconds(400))

        CoverArtCache.save(fresh)
        withAnimation(.easeInOut(duration: 0.8)) {
            coverSongs = fresh
        }
    }
}

#Preview {
    SignInView(onSignedIn: { _ in }, onSignedInWithEmail: { _ in })
}
