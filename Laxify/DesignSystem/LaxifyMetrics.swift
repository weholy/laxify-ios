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

    // MARK: - Controls
    //
    // One size for each kind of button, everywhere. Before these existed the
    // round buttons in screen headers came in twelve different sizes between
    // 32 and 64 points and the close button was built three different ways,
    // so moving from one screen to the next the same control jumped in size.

    /// Every round button that sits in a screen's header or toolbar: close,
    /// back, settings, share, more. Forty-four is Apple's minimum comfortable
    /// touch target, so nothing in a header is ever smaller than that.
    static let controlSize: CGFloat = 44
    /// The glyph inside a header control.
    static let controlGlyph: CGFloat = 17
    /// Round buttons inside a row — the "more" on a track, a play button on a
    /// card. Smaller than a header control, and all the same as each other.
    static let inlineControlSize: CGFloat = 36
    static let inlineControlGlyph: CGFloat = 15
    /// Full-width primary and secondary buttons.
    static let primaryButtonHeight: CGFloat = 52
}
