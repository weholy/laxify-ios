import SwiftUI

/// Close/confirm control used across the modal screens.
///
/// Two things here are deliberate. It takes an explicit closure instead of
/// reading `@Environment(\.dismiss)`, because these screens are presented
/// several modal layers deep and the environment value does not reliably
/// reach the layer being dismissed. And it carries its own generous hit area
/// via `contentShape`, so a tap near the glyph counts even when the button
/// sits above a scroll view that would otherwise swallow it.
struct LaxifyCloseButton: View {
    enum Style {
        case checkmark
        case chevronDown
        case xmark

        var symbol: String {
            switch self {
            case .checkmark: "checkmark"
            case .chevronDown: "chevron.down"
            case .xmark: "xmark"
            }
        }
    }

    var style: Style = .checkmark
    var tinted: Bool = true
    var action: () -> Void

    private let diameter: CGFloat = LaxifyMetrics.controlSize

    /// Deliberately **not** interactive glass.
    ///
    /// `.interactive()` installs its own gesture recogniser, and inside a
    /// scrolling view that recogniser and the scroll gesture fight over the
    /// tap — the scroll usually wins. Four screens put this button in a
    /// scroll view (a playlist opened from search, an artist, one of your own
    /// playlists, search itself) and on all four the button only answered
    /// occasionally, or not at all. Plain glass has no recogniser of its own,
    /// so the button behaves like a button; the press feedback comes from
    /// `PressableStyle`, which was already here.
    var body: some View {
        Button(action: action) {
            Image(systemName: style.symbol)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(tinted ? .white : LaxifyPalette.textPrimary)
                .frame(width: diameter, height: diameter)
                .glassEffect(
                    tinted ? .regular.tint(LaxifyPalette.accent) : .regular,
                    in: Circle()
                )
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
    }
}

private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Compact pill used for secondary actions in a screen header.
struct LaxifyPillButton: View {
    let title: String
    var systemImage: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(title)
                    .font(LaxifyTypography.subheadline)
            }
            .foregroundStyle(LaxifyPalette.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular.interactive(), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
    }
}
