import SwiftUI

/// Brings a view in slightly after the one above it.
///
/// A screen whose parts all appear at the same instant reads as a picture
/// being switched on. Staggering them by a few hundredths reads as the screen
/// assembling itself, which is both calmer and hides the moment the numbers
/// arrive from the network.
private struct Reveal: ViewModifier {
    let delay: Double
    let isActive: Bool

    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 14)
            .onChange(of: isActive, initial: true) { _, active in
                guard active, !shown else { return }
                withAnimation(.spring(response: 0.5, dampingFraction: 0.86).delay(delay)) {
                    shown = true
                }
            }
    }
}

extension View {
    /// Fades and lifts this view into place once `when` becomes true.
    func revealed(after delay: Double, when isActive: Bool) -> some View {
        modifier(Reveal(delay: delay, isActive: isActive))
    }
}
