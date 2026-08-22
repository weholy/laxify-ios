import SwiftUI

struct SignInView: View {
    var onSignedIn: (AuthenticatedGoogleUser) async -> Void

    @State private var isSigningIn = false
    @State private var errorMessage: String?
    @State private var appear = false
    @State private var buttonAppear = false
    @State private var coverSongs: [Song] = CoverArtCache.load()

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

    /// Refreshes the backdrop artwork.
    ///
    /// The term is picked at random and mixed with a second query so the wall
    /// differs between launches instead of always showing the same chart.
    /// Cached covers are already on screen, so a failure here changes nothing
    /// visible.
    private func loadCovers() async {
        var collected: [Song] = []
        var seen = Set(coverSongs.map(\.id))

        for term in Self.coverSearchTerms.shuffled().prefix(3) {
            guard !Task.isCancelled else { return }

            do {
                let results = try await CatalogService.shared.search(query: term)
                for song in results.tracks where song.coverURL != nil && !seen.contains(song.id) {
                    seen.insert(song.id)
                    collected.append(song)
                }
            } catch {
                AppLogger.log("signin: covers failed for \(term) — \(error)")
            }

            if collected.count >= 16 { break }
        }

        guard collected.count >= 6 else {
            AppLogger.log("signin: not enough covers, keeping what is shown")
            return
        }

        let fresh = collected.shuffled()
        CoverArtCache.save(fresh)

        withAnimation(.easeInOut(duration: 0.8)) {
            coverSongs = fresh
        }
    }

    /// A deliberately wide mix so the backdrop is not always Russian chart
    /// covers — the reference wall reads as "all music", not one scene.
    private static let coverSearchTerms = [
        "хиты", "новинки", "русский рэп", "поп музыка",
        "Travis Scott", "Kendrick Lamar", "Drake", "Eminem",
        "Kanye West", "Playboi Carti", "21 Savage", "Metro Boomin",
        "The Weeknd", "Tyler The Creator", "Future", "Lil Peep",
        "рок", "электронная музыка", "джаз", "инди"
    ]
}

#Preview {
    SignInView(onSignedIn: { _ in })
}
