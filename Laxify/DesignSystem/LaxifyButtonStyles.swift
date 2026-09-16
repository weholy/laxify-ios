import SwiftUI

struct LaxifyPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(LaxifyTypography.headline)
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .glassEffect(.regular.tint(LaxifyPalette.accent).interactive(), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct LaxifySecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(LaxifyTypography.headline)
            .foregroundStyle(LaxifyPalette.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .laxGlassCapsule(interactive: true)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct LaxifyIconButtonStyle: ButtonStyle {
    var diameter: CGFloat = LaxifyMetrics.controlSize

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

struct LaxifyCheckmarkButtonStyle: ButtonStyle {
    var diameter: CGFloat = LaxifyMetrics.controlSize

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: diameter, height: diameter)
            .glassEffect(.regular.tint(LaxifyPalette.accent).interactive(), in: Circle())
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
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

extension ButtonStyle where Self == LaxifyCheckmarkButtonStyle {
    static var laxifyCheckmark: LaxifyCheckmarkButtonStyle { LaxifyCheckmarkButtonStyle() }
}
