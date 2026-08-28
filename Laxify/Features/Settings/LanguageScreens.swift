import SwiftUI

/// The first screen a new install shows — pick a language before anything
/// else. Titles preview in the language under the finger.
struct LanguagePickerView: View {
    var localization = LocalizationManager.shared
    @State private var selected: AppLanguage = LocalizationManager.shared.language
    @State private var appear = false

    var body: some View {
        ZStack {
            LaxifyPalette.background.ignoresSafeArea()

            LinearGradient(
                colors: [LaxifyPalette.accent.opacity(0.18), .clear],
                startPoint: .top, endPoint: .center
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(preview("language.title", "Выберите язык"))
                        .font(.system(size: 32, weight: .heavy))
                        .foregroundStyle(LaxifyPalette.textPrimary)
                    Text(preview("language.subtitle", "Это можно изменить в настройках"))
                        .font(LaxifyTypography.footnote)
                        .foregroundStyle(LaxifyPalette.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, LaxifyMetrics.screenPadding)
                .padding(.top, 24)
                .padding(.bottom, 28)

                VStack(spacing: 12) {
                    ForEach(AppLanguage.allCases) { language in
                        row(language)
                    }
                }
                .padding(.horizontal, LaxifyMetrics.screenPadding)

                Spacer()

                Button {
                    localization.choose(selected)
                } label: {
                    Text(preview("language.continue", "Продолжить"))
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 17)
                        .background(LaxifyPalette.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, LaxifyMetrics.screenPadding)
                .padding(.bottom, 24)
            }
            .opacity(appear ? 1 : 0)
            .offset(y: appear ? 0 : 16)
        }
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.85)) { appear = true }
        }
    }

    private func preview(_ key: String, _ fallback: String) -> String {
        Translations.table[selected]?[key] ?? Translations.table[.en]?[key] ?? fallback
    }

    private func row(_ language: AppLanguage) -> some View {
        let isSelected = selected == language
        return Button {
            withAnimation(.snappy(duration: 0.2)) { selected = language }
        } label: {
            HStack(spacing: 14) {
                Text(language.flag).font(.system(size: 26))

                VStack(alignment: .leading, spacing: 2) {
                    Text(language.nativeName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(LaxifyPalette.textPrimary)
                    Text(language.englishName)
                        .font(LaxifyTypography.caption)
                        .foregroundStyle(LaxifyPalette.textSecondary)
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? LaxifyPalette.accent : LaxifyPalette.textTertiary)
                    .contentTransition(.symbolEffect)
            }
            .padding(16)
            .background(LaxifyPalette.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(isSelected ? LaxifyPalette.accent : .clear, lineWidth: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
