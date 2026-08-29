import CoreGraphics

enum LaxifyMetrics {
    static let screenPadding: CGFloat = 20
    static let sectionSpacing: CGFloat = 28
    static let itemSpacing: CGFloat = 12

    // Pulled in toward Telegram's geometry — a toast at 25, cards no rounder
    // than they need to be.
    static let cardCornerRadius: CGFloat = 18
    static let smallCornerRadius: CGFloat = 12
    static let artworkCornerRadius: CGFloat = 14
    static let groupedCornerRadius: CGFloat = 11
    static let toastCornerRadius: CGFloat = 25
    /// Each settings entry is its own free-standing pill-ish card now.
    static let settingsCardCornerRadius: CGFloat = 24

    static let tabBarHeight: CGFloat = 58
    static let tabBarBottomInset: CGFloat = 12
    static let searchButtonDiameter: CGFloat = 58

    static let miniPlayerHeight: CGFloat = 56
    static let miniPlayerCornerRadius: CGFloat = 26
}
