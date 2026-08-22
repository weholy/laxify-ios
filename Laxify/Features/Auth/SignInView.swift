import SwiftUI

struct SignInView: View {
    var onSignedIn: (AuthenticatedGoogleUser) async -> Void

    @State private var isSigningIn = false
    @State private var errorMessage: String?
    @State private var appear = false
    @State private var logoAppear = false
    @State private var buttonAppear = false
    @State private var coverSongs: [Song] = []

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
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.7).delay(0.1)) {
                logoAppear = true
            }
            withAnimation(.easeOut(duration: 0.6).delay(0.28)) {
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
            logo
                .padding(.bottom, 18)
                .opacity(logoAppear ? 1 : 0)

            Text("Вся твоя музыка\nв одном месте")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(LaxifyPalette.textPrimary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.bottom, 28)

            googleButton
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

    private var logo: some View {
        Image("LaxifyLogo")
            .resizable()
            .scaledToFill()
            .frame(width: 74, height: 74)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
            .scaleEffect(logoAppear ? 1 : 0.7)
            .rotationEffect(.degrees(logoAppear ? 0 : -12))
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
                    GoogleLogoView(size: 19)
                        .padding(3)
                        .background(Circle().fill(.white))
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

    /// Fills the backdrop with real artwork.
    ///
    /// Several terms are tried in turn because a single query can come back
    /// empty for reasons that have nothing to do with the app — a regional
    /// block, a slow first call while the session is established, or a term
    /// that simply matched nothing. The gradient wall stays up meanwhile, so
    /// a failure here is invisible rather than an empty screen.
    private func loadCovers() async {
        guard coverSongs.isEmpty else { return }

        for term in ["хиты", "популярное", "новинки", "рэп"] {
            guard !Task.isCancelled else { return }

            do {
                let results = try await YandexMusicService.shared.search(query: term)
                let tracks = results.tracks.filter { $0.coverURL != nil }

                if tracks.count >= 4 {
                    withAnimation(.easeInOut(duration: 0.7)) {
                        coverSongs = Array(tracks.prefix(12))
                    }
                    return
                }
            } catch {
                AppLogger.log("signin: covers failed for \(term) — \(error)")
            }
        }

        AppLogger.log("signin: no covers loaded, keeping placeholders")
    }
}

#Preview {
    SignInView(onSignedIn: { _ in })
}
