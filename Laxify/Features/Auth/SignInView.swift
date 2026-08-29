import SwiftUI
import UIKit

struct SignInView: View {
    var onSignedIn: (AuthenticatedGoogleUser) async -> Void

    @State private var isSigningIn = false
    @State private var errorMessage: String?
    @State private var appear = false
    @State private var buttonAppear = false
    @State private var coverSongs: [Song] = CoverArtCache.load()
    @State private var showsTerms = false
    @State private var showsTelegram = false
    @State private var serverUnreachable = false
    private var session: SessionStore { SessionStore.shared }

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
        .task {
            // Nothing answered the probe: signing in is not going to work
            // here, so offer the way in that does not need us.
            let routes = await LaxifyAPI.shared.routeReport()
            if !routes.isEmpty, routes.values.allSatisfy({ !$0 }) {
                withAnimation(.easeOut(duration: 0.3)) { serverUnreachable = true }
            }
        }
        .sheet(isPresented: $showsTerms) {
            TermsView { showsTerms = false }
        }
        .sheet(isPresented: $showsTelegram) {
            TelegramLoginSheet(
                onResult: { params in handleTelegram(params) },
                onCancel: { showsTelegram = false }
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
            // Nothing at all until there is real artwork to show. Coloured
            // squares standing in for covers were visible for a moment on
            // every cold launch, and a moment is enough to notice.
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

            Text(L("signin.tagline", "Вся твоя музыка\nв одном месте"))
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(LaxifyPalette.textPrimary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.bottom, 28)

            VStack(spacing: 12) {
                googleButton
                telegramButton

                if serverUnreachable {
                    guestButton
                }
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

            Button {
                showsTerms = true
            } label: {
                Text(L("signin.terms1", "Продолжая, вы принимаете "))
                    .foregroundStyle(LaxifyPalette.textTertiary)
                + Text(L("signin.terms2", "условия использования"))
                    .foregroundStyle(LaxifyPalette.textSecondary)
                    .underline()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .multilineTextAlignment(.center)
            .padding(.top, 14)
            .padding(.horizontal, 32)
        }
        .padding(.bottom, 28)
        .opacity(appear ? 1 : 0)
        .offset(y: appear ? 0 : 20)
    }


    /// The way in that does not depend on Google being reachable.
    /// Offered only when the server cannot be reached at all.
    ///
    /// On some networks our server is unreachable while the music is not, and
    /// an app that is nothing but a sign-in screen is worse than one that
    /// plays. Whatever is collected without an account goes up when one is
    /// added.
    private var guestButton: some View {
        Button {
            session.continueAsGuest()
        } label: {
            Text(L("signin.guest", "Слушать без аккаунта"))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(LaxifyPalette.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
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

                Text(isSigningIn ? L("signin.googleLoading", "Входим…") : L("signin.google", "Продолжить с Google"))
                    .font(.system(size: 17, weight: .semibold))
            }
            .foregroundStyle(LaxifyPalette.background)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 17)
            .background(LaxifyPalette.textPrimary, in: Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
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
                    errorMessage = L("signin.error", "Не удалось войти. Попробуйте ещё раз")
                }
                AppLogger.log("auth: sign-in failed \(error)")
            }
        }
    }

    private var telegramButton: some View {
        Button {
            withAnimation { errorMessage = nil }
            showsTelegram = true
        } label: {
            HStack(spacing: 10) {
                TelegramLogoView(size: 21)
                Text(L("signin.telegram", "Продолжить с Telegram"))
                    .font(.system(size: 17, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 17)
            .background(Color(hex: 0x2AABEE), in: Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(Color(hex: 0x2AABEE)).interactive(), in: .capsule)
        .disabled(isSigningIn)
    }

    /// The Telegram widget signed the user in on the web page; hand the
    /// payload to the backend and let SessionStore drive the screen swap.
    private func handleTelegram(_ params: [String: String]) {
        showsTelegram = false
        guard !params.isEmpty else { return }
        withAnimation { errorMessage = nil }
        isSigningIn = true
        Task {
            let ok = await session.signInWithTelegram(
                payload: params, deviceName: UIDevice.current.name
            )
            isSigningIn = false
            if !ok {
                withAnimation {
                    errorMessage = session.lastError
                        ?? L("signin.error", "Не удалось войти. Попробуйте ещё раз")
                }
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
    SignInView(onSignedIn: { _ in })
}
