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
        HStack(spacing: 12) {
            statTile(
                value: formattedHours,
                unit: "ч",
                label: "Прослушано",
                icon: "headphones",
                iconColor: LaxifyPalette.accent
            )
            statTile(
                value: "\(stats.currentStreak)",
                unit: "",
                label: streakLabel,
                icon: "flame.fill",
                iconColor: .orange
            )
        }
        .padding(.horizontal, LaxifyMetrics.screenPadding)
    }

    private func statTile(value: String, unit: String, label: String, icon: String, iconColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(iconColor)

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(LaxifyPalette.textPrimary)
                if !unit.isEmpty {
                    Text(unit)
                        .font(LaxifyTypography.subheadline)
                        .foregroundStyle(LaxifyPalette.textSecondary)
                }
            }

            Text(label)
                .font(LaxifyTypography.footnote)
                .foregroundStyle(LaxifyPalette.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .laxGlassCard()
    }

    private var formattedHours: String {
        String(format: "%.1f", stats.totalSecondsListened / 3600)
    }

    private var streakLabel: String {
        let remainder10 = stats.currentStreak % 10
        let remainder100 = stats.currentStreak % 100
        if remainder10 == 1, remainder100 != 11 {
            return "день подряд"
        } else if (2...4).contains(remainder10), !(12...14).contains(remainder100) {
            return "дня подряд"
        } else {
            return "дней подряд"
        }
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
