import SwiftUI

/// "Ваша волна" — the wave's three dials as image cards rather than plain
/// chips: a gradient keyed to each option and a big faint glyph, the chosen
/// one ringed and checked.
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

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    section(title: "Настроение", options: WaveSettings.Mood.allCases,
                            selection: settings.mood, titleFor: \.title) { settings.mood = $0 }

                    section(title: "Что играть", options: WaveSettings.Diversity.allCases,
                            selection: settings.diversity, titleFor: \.title) { settings.diversity = $0 }

                    section(title: "Язык", options: WaveSettings.Language.allCases,
                            selection: settings.language, titleFor: \.title) { settings.language = $0 }
                }
                .padding(.horizontal, LaxifyMetrics.screenPadding)
                .padding(.top, 6)
                .padding(.bottom, 24)
            }

            applyButton
        }
        .background(LaxifyPalette.background.ignoresSafeArea())
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Ваша волна")
                    .font(.system(size: 32, weight: .heavy))
                    .foregroundStyle(LaxifyPalette.textPrimary)
                Text("Подстройте под настроение")
                    .font(LaxifyTypography.footnote)
                    .foregroundStyle(LaxifyPalette.textSecondary)
            }

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(LaxifyPalette.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(LaxifyPalette.surface, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, LaxifyMetrics.screenPadding)
        .padding(.top, 18)
        .padding(.bottom, 22)
    }

    private func section<Option: RawRepresentable & Hashable & CaseIterable>(
        title: String,
        options: [Option],
        selection: Option,
        titleFor: KeyPath<Option, String>,
        onSelect: @escaping (Option) -> Void
    ) -> some View where Option.RawValue == String {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(LaxifyPalette.textPrimary)

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(options, id: \.self) { option in
                    WaveOptionCard(
                        title: option[keyPath: titleFor],
                        style: .forOption(option.rawValue),
                        isSelected: option == selection
                    ) {
                        onSelect(option)
                    }
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
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 17)
                .background(
                    LinearGradient(
                        colors: [LaxifyPalette.accent, LaxifyPalette.accent.opacity(0.75)],
                        startPoint: .leading, endPoint: .trailing
                    ),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, LaxifyMetrics.screenPadding)
        .padding(.top, 8)
        .padding(.bottom, 18)
    }
}

// MARK: - Option card

private struct WaveOptionStyle {
    let colors: [Color]
    let symbol: String

    static func forOption(_ raw: String) -> WaveOptionStyle {
        switch raw {
        // Mood
        case "all": .init(colors: [.init(hex: 0x6D5DF6), .init(hex: 0x3B2E8C)], symbol: "infinity")
        case "fun": .init(colors: [.init(hex: 0xFFB03A), .init(hex: 0xFF6B35)], symbol: "sun.max.fill")
        case "active": .init(colors: [.init(hex: 0xFF5FA2), .init(hex: 0xE0245E)], symbol: "bolt.fill")
        case "calm": .init(colors: [.init(hex: 0x2AB7CA), .init(hex: 0x1E6091)], symbol: "leaf.fill")
        case "sad": .init(colors: [.init(hex: 0x5B6B8C), .init(hex: 0x2C3550)], symbol: "cloud.rain.fill")
        // Diversity
        case "default": .init(colors: [.init(hex: 0x8E9AAF), .init(hex: 0x4A5568)], symbol: "square.stack.3d.up.fill")
        case "favorite": .init(colors: [.init(hex: 0xFF6B9D), .init(hex: 0xC1121F)], symbol: "heart.fill")
        case "popular": .init(colors: [.init(hex: 0xFFB300), .init(hex: 0xF57C00)], symbol: "flame.fill")
        case "discover": .init(colors: [.init(hex: 0xA855F7), .init(hex: 0x6D28D9)], symbol: "sparkles")
        // Language
        case "any": .init(colors: [.init(hex: 0x4ECDC4), .init(hex: 0x556270)], symbol: "globe")
        case "russian": .init(colors: [.init(hex: 0x2A61FF), .init(hex: 0x1E3A8A)], symbol: "character.book.closed.fill")
        case "notRussian": .init(colors: [.init(hex: 0x00B4D8), .init(hex: 0x0077B6)], symbol: "airplane")
        default: .init(colors: [.init(hex: 0x6D5DF6), .init(hex: 0x3B2E8C)], symbol: "music.note")
        }
    }
}

private struct WaveOptionCard: View {
    let title: String
    let style: WaveOptionStyle
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) { action() }
        } label: {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: style.colors, startPoint: .topLeading, endPoint: .bottomTrailing)

                Image(systemName: style.symbol)
                    .font(.system(size: 52, weight: .bold))
                    .foregroundStyle(.white.opacity(0.16))
                    .offset(x: 42, y: 16)

                Text(title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(14)
            }
            .frame(height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(.white, lineWidth: isSelected ? 2.5 : 0)
            }
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(.black)
                        .frame(width: 26, height: 26)
                        .background(.white, in: Circle())
                        .padding(9)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .buttonStyle(WaveCardPressStyle())
    }
}

private struct WaveCardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
