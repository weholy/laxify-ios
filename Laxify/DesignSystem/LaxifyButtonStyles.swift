import SwiftUI

struct LaxifyPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(LaxifyTypography.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(LaxifyPalette.accent, in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct LaxifySecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(LaxifyTypography.headline)
            .foregroundStyle(LaxifyPalette.textPrimary)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .laxGlassCapsule(interactive: true)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct LaxifyIconButtonStyle: ButtonStyle {
    var diameter: CGFloat = 44

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(LaxifyPalette.textPrimary)
            .frame(width: diameter, height: diameter)
            .laxGlassCircle(interactive: true)
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == LaxifyPrimaryButtonStyle {
    static var laxifyPrimary: LaxifyPrimaryButtonStyle { LaxifyPrimaryButtonStyle() }
}

extension ButtonStyle where Self == LaxifySecondaryButtonStyle {
    static var laxifySecondary: LaxifySecondaryButtonStyle { LaxifySecondaryButtonStyle() }
}

extension ButtonStyle where Self == LaxifyIconButtonStyle {
    static var laxifyIcon: LaxifyIconButtonStyle { LaxifyIconButtonStyle() }
}
