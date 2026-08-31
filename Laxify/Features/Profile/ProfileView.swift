import SwiftUI

struct ProfileView: View {
    @State private var session = SessionStore.shared

    @State private var isSettingsPresented = false
    @State private var isReplayPresented = false
    @State private var avatarPalette: ArtworkPalette = .neutral
    @State private var likeCount: Int?

    private var user: BackendUser? { session.user }

    var body: some View {
        // The header sits outside the ScrollView: layered over a scroll view
        // the button only caught occasional taps, because the scroll gesture
        // consumed most of them.
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(spacing: LaxifyMetrics.sectionSpacing) {
                    if let user {
                        identitySection(user)
                    }

                    ReplayEntryCard { _, _ in
                        isReplayPresented = true
                    }
                    .padding(.horizontal, LaxifyMetrics.screenPadding)

                }
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
        }
        .background(profileBackground)
        .task {
            await session.refreshUser()
            if let id = session.user?.id {
                likeCount = (try? await LaxifyAPI.shared.profileLikes(userId: id))?.likeCount
            }
        }
        // Keyed on the picture rather than run once: change the avatar and
        // the colour wash behind the header follows it immediately.
        .task(id: session.user?.avatarURL) {
            avatarPalette = await PaletteExtractor.shared.palette(for: session.user?.avatarURL)
        }
        .fullScreenCover(isPresented: $isSettingsPresented) {
            SettingsView { isSettingsPresented = false }
        }
        .fullScreenCover(isPresented: $isReplayPresented) {
            ReplayView { isReplayPresented = false }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Spacer()

            if user != nil {
                Button {
                    isSettingsPresented = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(LaxifyPalette.textPrimary)
                        .frame(width: 48, height: 48)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, LaxifyMetrics.screenPadding)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    /// A wash of the avatar's own colour at the top, fading into the page.
    ///
    /// A blurred copy of the picture sat as a visibly different image over a
    /// dark page — brown over black, with an edge where it ended. Taking the
    /// colour and painting a gradient with it belongs to the page instead of
    /// sitting on it.
    private var profileBackground: some View {
        ZStack(alignment: .top) {
            LaxifyPalette.background

            LinearGradient(
                colors: [
                    avatarPalette.accent.opacity(0.55),
                    avatarPalette.dominant.opacity(0.28),
                    LaxifyPalette.background.opacity(0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 460)
            .animation(.easeInOut(duration: 0.6), value: avatarPalette)
        }
        .ignoresSafeArea()
    }

    private func identitySection(_ user: BackendUser) -> some View {
        VStack(spacing: 14) {
            avatarView(user)
                .frame(width: 104, height: 104)
                .clipShape(Circle())
                .overlay { Circle().stroke(.white.opacity(0.15), lineWidth: 1) }
                .shadow(color: .black.opacity(0.3), radius: 20, y: 10)

            VStack(spacing: 3) {
                Text(user.displayName)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(LaxifyPalette.textPrimary)

                Text("@\(user.username)")
                    .font(LaxifyTypography.subheadline)
                    .foregroundStyle(LaxifyPalette.textSecondary)

                if let likeCount, likeCount > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "heart.fill").foregroundStyle(.red)
                        Text("\(likeCount)")
                            .monospacedDigit()
                            .foregroundStyle(LaxifyPalette.textSecondary)
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.top, 3)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, LaxifyMetrics.screenPadding)
    }

    /// Through the shared image cache rather than `AsyncImage`.
    ///
    /// `AsyncImage` refetches on every appearance, which is why the avatar sat
    /// blank for a moment each time this screen opened; `CachedImage` keeps
    /// the decoded picture and is keyed on the url, so a new photo still
    /// replaces the old one straight away.
    private func avatarView(_ user: BackendUser) -> some View {
        CachedImage(url: user.avatarURL, displaySize: 220) {
            Circle()
                .fill(LaxifyPalette.surface)
                .overlay {
                    Image(systemName: "person.fill")
                        .foregroundStyle(LaxifyPalette.textTertiary)
                }
        }
    }

}

#Preview {
    ProfileView()
}
