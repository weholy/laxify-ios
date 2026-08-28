import SwiftUI

/// Settings → Информация: where to follow the project and how to support it.
struct InfoSettingsView: View {
    var onBack: () -> Void

    @Environment(\.openURL) private var openURL

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    var body: some View {
        SettingsPage(title: L("settings.info", "Информация"), status: nil, onBack: onBack) {
            SettingsCard {
                linkRow(
                    icon: "paperplane.fill",
                    tint: Color(hex: 0x27A7E7),
                    title: L("info.telegram", "Telegram-канал"),
                    subtitle: L("info.telegram.sub", "Новости и новые сборки"),
                    url: AppLinks.telegramChannel
                )

                SettingsDivider()

                linkRow(
                    icon: "heart.fill",
                    tint: Color(hex: 0xFF4D6D),
                    title: L("info.support", "Поддержать проект"),
                    subtitle: L("info.support.sub", "Помочь развитию Laxify"),
                    url: AppLinks.support
                )
            }

            SettingsCard {
                HStack {
                    Text(L("info.version", "Версия"))
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(LaxifyPalette.textPrimary)
                    Spacer()
                    Text(appVersion)
                        .font(LaxifyTypography.footnote)
                        .foregroundStyle(LaxifyPalette.textSecondary)
                        .monospacedDigit()
                }
                .padding(16)
            }
        }
    }

    private func linkRow(icon: String, tint: Color, title: String, subtitle: String, url: URL) -> some View {
        Button {
            openURL(url)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(tint, in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(LaxifyPalette.textPrimary)
                    Text(subtitle)
                        .font(LaxifyTypography.footnote)
                        .foregroundStyle(LaxifyPalette.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LaxifyPalette.textTertiary)
            }
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A bottom banner that asks for a relaunch when a setting only takes effect
/// on next launch. Rectangular, sits above the home indicator.
struct RestartBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(LaxifyPalette.accent)

            Text(L("restart.banner", "Перезапустите Laxify — для применения настроек"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(LaxifyPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(LaxifyPalette.surfaceElevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(LaxifyPalette.separator, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
        .padding(.horizontal, LaxifyMetrics.screenPadding)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
