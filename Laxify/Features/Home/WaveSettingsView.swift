import SwiftUI

struct WaveSettingsView: View {
    @State private var settings: WaveSettings
    private let onApply: (WaveSettings) -> Void
    private let onClose: () -> Void

    init(
        settings: WaveSettings,
        onApply: @escaping (WaveSettings) -> Void,
        onClose: @escaping () -> Void
    ) {
        _settings = State(initialValue: settings)
        self.onApply = onApply
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    section(
                        title: "Настроение",
                        options: WaveSettings.Mood.allCases,
                        selection: settings.mood,
                        titleFor: \.title
                    ) { settings.mood = $0 }

                    section(
                        title: "Что играть",
                        options: WaveSettings.Diversity.allCases,
                        selection: settings.diversity,
                        titleFor: \.title
                    ) { settings.diversity = $0 }

                    section(
                        title: "Язык",
                        options: WaveSettings.Language.allCases,
                        selection: settings.language,
                        titleFor: \.title
                    ) { settings.language = $0 }
                }
                .padding(.horizontal, LaxifyMetrics.screenPadding)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }

            applyButton
        }
        .background(LaxifyPalette.background.ignoresSafeArea())
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Ваша волна")
                    .font(LaxifyTypography.largeTitle)
                    .foregroundStyle(LaxifyPalette.textPrimary)
                Text("Подстройте под настроение")
                    .font(LaxifyTypography.footnote)
                    .foregroundStyle(LaxifyPalette.textSecondary)
            }

            Spacer()

            LaxifyCloseButton(style: .xmark, tinted: false, action: onClose)
        }
        .padding(.horizontal, LaxifyMetrics.screenPadding)
        .padding(.top, 16)
        .padding(.bottom, 20)
    }

    private func section<Option: Hashable & CaseIterable>(
        title: String,
        options: [Option],
        selection: Option,
        titleFor: KeyPath<Option, String>,
        onSelect: @escaping (Option) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(LaxifyTypography.title)
                .foregroundStyle(LaxifyPalette.textPrimary)

            LaxifyChipFlow(spacing: 10) {
                ForEach(options, id: \.self) { option in
                    let isSelected = option == selection
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                            onSelect(option)
                        }
                    } label: {
                        Text(option[keyPath: titleFor])
                            .font(LaxifyTypography.subheadline)
                            .foregroundStyle(isSelected ? .white : LaxifyPalette.textPrimary)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 11)
                            .background {
                                if isSelected {
                                    Capsule().fill(LaxifyPalette.accent)
                                } else {
                                    Capsule().fill(LaxifyPalette.surface)
                                }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var applyButton: some View {
        Button {
            onApply(settings)
            onClose()
        } label: {
            Text("Применить")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.laxifyPrimary)
        .padding(.horizontal, LaxifyMetrics.screenPadding)
        .padding(.bottom, 20)
    }
}

/// Wraps chips onto as many lines as they need — reuses the same layout the
/// karaoke line uses, since the problem is identical.
private struct LaxifyChipFlow<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        WordFlowLayout(horizontalSpacing: spacing, lineSpacing: spacing) {
            content
        }
    }
}
