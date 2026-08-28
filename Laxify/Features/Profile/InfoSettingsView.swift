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

/// The "restart to apply" notice, copied from Telegram's undo/info toast:
/// a dark blurred bar (corner radius 25) with a round white "i" (radius 16)
/// and 14pt text. Never a modal — settings keep working while it is up, and
/// it stays until the change is actually applied on the next launch.
struct RestartBanner: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "info")
                .font(.system(size: 16, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            Text(L("restart.banner", "Перезапустите Laxify — настройка встанет на все экраны."))
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: LaxifyMetrics.toastCornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
                .overlay(
                    RoundedRectangle(cornerRadius: LaxifyMetrics.toastCornerRadius, style: .continuous)
                        .fill(.black.opacity(0.35))
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: LaxifyMetrics.toastCornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 24, y: 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
