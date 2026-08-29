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

/// A faithful re-creation of Telegram's `.info` undo/overlay toast — the exact
/// surface Netegram shows its "Перезапустите Netegram …" notices on
/// (`netegramPresentRestartToast` → `UndoOverlayController(content: .info(…))`).
///
/// Values lifted straight from Telegram's `UndoOverlayControllerNode`:
///   • panel  — corner radius 25, `.continuous`, dark blur, no border
///   • icon   — the info glyph on a `#474747` disc, in a 50pt layout column
///   • text   — system regular 14, white, up to 10 lines, leading-aligned,
///              vertically centred against the icon
///   • height — 20pt of vertical padding + text, floored to 50
///   • inset  — 12pt from each screen edge (applied by the caller)
/// Never a modal: the setting keeps working while the notice is up, and it
/// stays until the change is actually applied on the next launch.
struct RestartBanner: View {
    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            // Telegram's 50pt `leftInset` column the text is laid out against.
            ZStack {
                Circle()
                    .fill(Color(hex: 0x474747))
                    .frame(width: 30, height: 30)
                Image(systemName: "info")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 50)

            Text(L("restart.banner", "Перезапустите Laxify — настройка встанет на все экраны."))
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.white)
                .lineLimit(10)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.trailing, 16)          // Telegram `rightInset`
        .padding(.vertical, 10)          // half of the 20pt base `contentHeight`
        .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: LaxifyMetrics.toastCornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
                .overlay {
                    RoundedRectangle(cornerRadius: LaxifyMetrics.toastCornerRadius, style: .continuous)
                        .fill(.black.opacity(0.5))
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: LaxifyMetrics.toastCornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.28), radius: 16, y: 6)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
