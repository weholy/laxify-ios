import SwiftUI
import SwiftData

struct ProfileView: View {
    @Query private var profiles: [UserProfile]
    var stats = ListeningStatsService.shared

    private var profile: UserProfile? { profiles.first }

    var body: some View {
        ScrollView {
            VStack(spacing: LaxifyMetrics.sectionSpacing) {
                if let profile {
                    identitySection(profile)
                }

                statsSection
            }
            .padding(.top, 32)
            .padding(.bottom, LaxifyMetrics.tabBarHeight + LaxifyMetrics.miniPlayerHeight + 40)
        }
        .background(profileBackground)
    }

    private var profileBackground: some View {
        ZStack {
            LaxifyPalette.background

            Group {
                if let profile, profile.avatarData == nil, let url = profile.googleAvatarURL {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image
                                .resizable()
                                .scaledToFill()
                                .blur(radius: 90)
                                .opacity(0.5)
                        }
                    }
                } else if let profile, let data = profile.avatarData, let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 90)
                        .opacity(0.5)
                } else {
                    LaxifyPalette.accent.opacity(0.22)
                        .blur(radius: 90)
                }
            }
            .frame(height: 420)
            .frame(maxHeight: .infinity, alignment: .top)

            LinearGradient(
                colors: [.clear, LaxifyPalette.background.opacity(0.8), LaxifyPalette.background],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .clipped()
        .ignoresSafeArea()
    }

    private var statsSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "headphones")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(LaxifyPalette.accent)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(formattedHours)
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .foregroundStyle(LaxifyPalette.textPrimary)
                    .contentTransition(.numericText())
                    .animation(.spring(response: 0.5, dampingFraction: 0.8), value: formattedHours)
                Text("ч")
                    .font(LaxifyTypography.title)
                    .foregroundStyle(LaxifyPalette.textSecondary)
            }

            Text("прослушано")
                .font(LaxifyTypography.footnote)
                .foregroundStyle(LaxifyPalette.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .laxGlassCard(cornerRadius: 26)
        .padding(.horizontal, LaxifyMetrics.screenPadding)
    }

    private var formattedHours: String {
        String(format: "%.1f", stats.totalSecondsListened / 3600)
    }

    private func identitySection(_ profile: UserProfile) -> some View {
        VStack(spacing: 14) {
            avatarView(profile)
                .frame(width: 104, height: 104)
                .clipShape(Circle())
                .overlay {
                    Circle().stroke(.white.opacity(0.15), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.3), radius: 20, y: 10)

            VStack(spacing: 3) {
                Text(profile.displayName)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(LaxifyPalette.textPrimary)
                if !profile.username.isEmpty {
                    Text("@\(profile.username)")
                        .font(LaxifyTypography.subheadline)
                        .foregroundStyle(LaxifyPalette.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, LaxifyMetrics.screenPadding)
    }

    @ViewBuilder
    private func avatarView(_ profile: UserProfile) -> some View {
        if let avatarData = profile.avatarData, let uiImage = UIImage(data: avatarData) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
        } else if let url = profile.googleAvatarURL {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    Circle().fill(LaxifyPalette.surface)
                }
            }
        } else {
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
