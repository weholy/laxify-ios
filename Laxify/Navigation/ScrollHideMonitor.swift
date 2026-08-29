import SwiftUI

/// Tracks whether the active tab is being scrolled down, so the bottom bar
/// can shrink out of the way — the iOS 26 "the chrome gets smaller while you
/// read" behaviour.
@MainActor
@Observable
final class ScrollHideMonitor {
    static let shared = ScrollHideMonitor()

    /// True when the user is scrolling down and not near the top.
    private(set) var isCollapsed = false

    private var lastOffset: CGFloat = 0
    private init() {}

    func report(offset: CGFloat) {
        // Near the top always shows the full bar.
        if offset < 90 {
            set(false)
            lastOffset = offset
            return
        }

        let delta = offset - lastOffset
        // A small dead zone so a jittery finger doesn't flip it.
        if delta > 8 {
            set(true)
        } else if delta < -8 {
            set(false)
        }
        lastOffset = offset
    }

    /// A tab appearing resets it — otherwise switching tabs inherits the
    /// previous one's collapsed state.
    func reset() {
        lastOffset = 0
        set(false)
    }

    private func set(_ value: Bool) {
        guard value != isCollapsed else { return }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            isCollapsed = value
        }
    }
}

extension View {
    /// Feeds this scroll view's vertical offset to the shared monitor.
    func tracksBottomBarHiding() -> some View {
        onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentOffset.y + geo.contentInsets.top
        } action: { _, newValue in
            ScrollHideMonitor.shared.report(offset: newValue)
        }
        .onAppear { ScrollHideMonitor.shared.reset() }
    }
}
