import SwiftUI
import SwiftData

struct ProfileView: View {
    @Query private var profiles: [UserProfile]
    var stats = ListeningStatsService.shared
    @State private var logText = AppLogger.readAll()

    private var profile: UserProfile? { profiles.first }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LaxifyMetrics.sectionSpacing) {
                Text("Профиль")
                    .font(LaxifyTypography.largeTitle)
                    .foregroundStyle(LaxifyPalette.textPrimary)
                    .padding(.horizontal, LaxifyMetrics.screenPadding)

                if let profile {
                    identitySection(profile)
                }

                statsSection

                diagnosticsSection
            }
            .padding(.top, 12)
            .padding(.bottom, LaxifyMetrics.tabBarHeight + LaxifyMetrics.miniPlayerHeight + 40)
        }
        .background(LaxifyPalette.background)
        .onAppear {
            logText = AppLogger.readAll()
        }
    }

    private var statsSection: some View {
        VStack(spacing: 6) {
            Image(systemName: "headphones")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(LaxifyPalette.accent)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(formattedHours)
                    .font(.system(size: 46, weight: .bold, design: .rounded))
                    .foregroundStyle(LaxifyPalette.textPrimary)
                Text("ч")
                    .font(LaxifyTypography.title)
                    .foregroundStyle(LaxifyPalette.textSecondary)
            }

            Text("прослушано")
                .font(LaxifyTypography.footnote)
                .foregroundStyle(LaxifyPalette.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var formattedHours: String {
        String(format: "%.1f", stats.totalSecondsListened / 3600)
    }

    private func identitySection(_ profile: UserProfile) -> some View {
        HStack(spacing: 14) {
            avatarView(profile)
                .frame(width: 64, height: 64)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(profile.displayName)
                    .font(LaxifyTypography.title)
                    .foregroundStyle(LaxifyPalette.textPrimary)
                if !profile.username.isEmpty {
                    Text("@\(profile.username)")
                        .font(LaxifyTypography.footnote)
                        .foregroundStyle(LaxifyPalette.textSecondary)
                }
            }

            Spacer()
        }
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

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Диагностика")
                    .font(LaxifyTypography.title)
                    .foregroundStyle(LaxifyPalette.textPrimary)

                Spacer()

                Button {
                    logText = AppLogger.readAll()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.laxifyIcon)

                Button {
                    AppLogger.clear()
                    logText = AppLogger.readAll()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.laxifyIcon)
            }

            ScrollView {
                Text(logText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(LaxifyPalette.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(height: 320)
            .background(LaxifyPalette.surface, in: RoundedRectangle(cornerRadius: LaxifyMetrics.smallCornerRadius, style: .continuous))

            Button {
                UIPasteboard.general.string = logText
            } label: {
                Label("Скопировать логи", systemImage: "doc.on.doc")
            }
            .buttonStyle(.laxifySecondary)
        }
        .padding(.horizontal, LaxifyMetrics.screenPadding)
    }
}

#Preview {
    ProfileView()
}
