import SwiftUI

extension View {
    func laxGlass(interactive: Bool = false, in shape: some Shape = Capsule()) -> some View {
        self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
    }

    func laxGlassCapsule(interactive: Bool = false) -> some View {
        laxGlass(interactive: interactive, in: Capsule())
    }

    func laxGlassCard(cornerRadius: CGFloat = LaxifyMetrics.cardCornerRadius, interactive: Bool = false) -> some View {
        laxGlass(interactive: interactive, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    func laxGlassCircle(interactive: Bool = false) -> some View {
        laxGlass(interactive: interactive, in: Circle())
    }

    /// A properly proportioned glass capsule around a short text action
    /// (Готово, Отмена, …) — one consistent treatment everywhere.
    func glassPill() -> some View {
        self
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(LaxifyPalette.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .glassEffect(.regular.interactive(), in: .capsule)
            .contentShape(Capsule())
    }
}
