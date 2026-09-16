import SwiftUI

/// Settings → Информация: where to follow the project and how to support it.
struct InfoSettingsView: View {
    var onBack: () -> Void

    @Environment(\.openURL) private var openURL

    /// Which document is open in the in-app browser, if any.
    @State private var legal: TermsView.Section?

    private var appVersion: String { AppVersion.full }

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
                legalRow(
                    icon: "doc.text.fill",
                    tint: Color(hex: 0x8E8E93),
                    title: L("info.terms", "Условия использования"),
                    subtitle: "laxify.cc/terms",
                    section: .terms
                )

                SettingsDivider()

                legalRow(
                    icon: "lock.fill",
                    tint: Color(hex: 0x34C759),
                    title: L("info.privacy", "Ваши данные"),
                    subtitle: "laxify.cc/privacy",
                    section: .privacy
                )
            }
            .sheet(item: $legal) { section in
                TermsView(onClose: { legal = nil }, initialSection: section)
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

    /// Same row, but opened inside the app rather than handed to Safari.
    private func legalRow(
        icon: String, tint: Color, title: String, subtitle: String, section: TermsView.Section
    ) -> some View {
        Button {
            legal = section
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

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LaxifyPalette.textTertiary)
            }
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
