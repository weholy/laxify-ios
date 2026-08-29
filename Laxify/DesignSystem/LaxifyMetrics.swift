import CoreGraphics

enum LaxifyMetrics {
    static let screenPadding: CGFloat = 20
    static let sectionSpacing: CGFloat = 28
    static let itemSpacing: CGFloat = 12

    // One card radius everywhere, matching the settings entries — every
    // free-standing rounded rectangle (settings rows, library rows, sheets,
    // stat cards) uses `cardCornerRadius`. Small chips and artwork keep their
    // own tighter radii.
    static let cardCornerRadius: CGFloat = 30
    static let smallCornerRadius: CGFloat = 12
    static let artworkCornerRadius: CGFloat = 14
    static let groupedCornerRadius: CGFloat = 11
    static let toastCornerRadius: CGFloat = 25
    /// Kept as an alias so older call sites still resolve to the one radius.
    static let settingsCardCornerRadius: CGFloat = 30

    static let tabBarHeight: CGFloat = 58
    static let tabBarBottomInset: CGFloat = 12
    static let searchButtonDiameter: CGFloat = 58

    static let miniPlayerHeight: CGFloat = 56
    static let miniPlayerCornerRadius: CGFloat = 26
}
