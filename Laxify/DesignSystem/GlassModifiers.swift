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

    /// A chunky glass rounded-rectangle around a short text action
    /// (Готово, Отмена, …) — one consistent treatment everywhere.
    func glassPill() -> some View {
        self
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(LaxifyPalette.textPrimary)
            .padding(.horizontal, 20)
            .padding(.vertical, 13)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
