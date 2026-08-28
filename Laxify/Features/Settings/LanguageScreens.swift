import SwiftUI

/// The first screen a new install shows — pick a language before anything
/// else. One tap selects and continues; there is nothing to get wrong.
struct LanguagePickerView: View {
    var localization = LocalizationManager.shared
    @State private var appear = false

    var body: some View {
        ZStack {
            LaxifyPalette.background.ignoresSafeArea()

            // A slow, dark wash of brand colour — texture, not a spotlight.
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                MeshGradient(
                    width: 3, height: 3,
                    points: [
                        [0, 0], [0.5, 0], [1, 0],
                        [0, 0.5],
                        [Float(0.5 + 0.12 * sin(t * 0.3)), Float(0.5 + 0.12 * cos(t * 0.24))],
                        [1, 0.5],
                        [0, 1], [0.5, 1], [1, 1]
                    ],
                    colors: [
                        .clear, Color(hex: 0xA855F7).opacity(0.10), .clear,
                        Color(hex: 0x5B7CFA).opacity(0.14), Color(hex: 0xFF5FA2).opacity(0.10), Color(hex: 0xA855F7).opacity(0.12),
                        .clear, Color(hex: 0x5B7CFA).opacity(0.08), .clear
                    ]
                )
                .blur(radius: 50)
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Выберите язык")
                        .font(.system(size: 34, weight: .heavy))
                        .foregroundStyle(LaxifyPalette.textPrimary)
                    Text("Choose your language · Elige tu idioma · 选择语言")
                        .font(LaxifyTypography.footnote)
                        .foregroundStyle(LaxifyPalette.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, LaxifyMetrics.screenPadding)
                .padding(.top, 20)
                .padding(.bottom, 32)

                VStack(spacing: 14) {
                    ForEach(AppLanguage.allCases) { language in
                        row(language)
                    }
                }
                .padding(.horizontal, LaxifyMetrics.screenPadding)

                Spacer()

                Text("Это можно изменить в настройках")
                    .font(.system(size: 12))
                    .foregroundStyle(LaxifyPalette.textTertiary)
                    .padding(.bottom, 22)
            }
            .opacity(appear ? 1 : 0)
            .offset(y: appear ? 0 : 14)
        }
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.86)) { appear = true }
        }
    }

    private func row(_ language: AppLanguage) -> some View {
        Button {
            localization.choose(language)
        } label: {
            HStack(spacing: 16) {
                Text(language.flag)
                    .font(.system(size: 28))
                    .frame(width: 52, height: 52)
                    .background(LaxifyPalette.surfaceElevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(language.nativeName)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(LaxifyPalette.textPrimary)
                    Text(language.englishName)
                        .font(LaxifyTypography.caption)
                        .foregroundStyle(LaxifyPalette.textSecondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(LaxifyPalette.textTertiary)
            }
            .padding(16)
            .background(LaxifyPalette.surface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .buttonStyle(LanguageRowPressStyle())
    }
}

private struct LanguageRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// The same choice, reachable later from Settings → Язык. Applies instantly.
struct LanguageSettingsView: View {
    var onBack: () -> Void

    var localization = LocalizationManager.shared

    var body: some View {
        SettingsPage(title: L("settings.language", "Язык"), status: nil, onBack: onBack) {
            VStack(spacing: 12) {
                ForEach(AppLanguage.allCases) { language in
                    row(language)
                }
            }
        }
    }

    private func row(_ language: AppLanguage) -> some View {
        let isSelected = localization.language == language
        return Button {
            withAnimation(.snappy(duration: 0.2)) { localization.choose(language) }
        } label: {
            HStack(spacing: 14) {
                Text(language.flag).font(.system(size: 24))

                Text(language.nativeName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(LaxifyPalette.textPrimary)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(LaxifyPalette.accent)
                }
            }
            .padding(16)
            .background(LaxifyPalette.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(isSelected ? LaxifyPalette.selectionOutline : .clear, lineWidth: isSelected ? 2 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
