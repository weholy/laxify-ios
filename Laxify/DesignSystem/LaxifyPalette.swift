import SwiftUI

enum LaxifyPalette {
    static let background = Color(light: .white, dark: .black)
    static let surface = Color(light: Color(hex: 0xF2F2F7), dark: Color(hex: 0x1C1C1E))
    static let surfaceElevated = Color(light: Color(hex: 0xFFFFFF), dark: Color(hex: 0x242426))
    static let separator = Color(light: Color(hex: 0xE5E5EA), dark: Color(hex: 0x2C2C2E))

    static let textPrimary = Color(light: Color(hex: 0x1C1C1E), dark: .white)
    static let textSecondary = Color(light: Color(hex: 0x6C6C70), dark: Color(hex: 0x98989F))
    static let textTertiary = Color(light: Color(hex: 0xA0A0A5), dark: Color(hex: 0x6C6C70))

    /// Taken from the app mark rather than the system blue, which belonged to
    /// iOS and not to Laxify. Slightly deeper in light mode, where the same
    /// violet on white reads as washed out.
    static let accent = Color(light: Color(hex: 0x8B3FE0), dark: Color(hex: 0xA855F7))
    static let accentMuted = Color(light: Color(hex: 0x8B3FE0, opacity: 0.12), dark: Color(hex: 0xA855F7, opacity: 0.18))

    /// The mark's own gradient, for the few places that carry the brand
    /// rather than merely use its colour.
    static let brandGradient = LinearGradient(
        colors: [Color(hex: 0xFF5FA2), Color(hex: 0xA855F7), Color(hex: 0x5B7CFA)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let glassTint = Color(light: .white.opacity(0.6), dark: .black.opacity(0.35))
}
