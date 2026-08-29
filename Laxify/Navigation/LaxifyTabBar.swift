import SwiftUI

struct LaxifyTabBar: View {
    @Binding var selectedTab: AppTab
    var onSearchTap: () -> Void

    @Namespace private var selectionNamespace
    /// Bumped on every search tap so the glyph replays its bounce even when
    /// the destination is a cover rather than a state change.
    @State private var searchBounce = 0

    private var hideLabels: Bool { AppearanceSettings.shared.hideTabLabelsApplied }

    var body: some View {
        GlassEffectContainer(spacing: 16) {
            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    ForEach(AppTab.allCases, id: \.self) { tab in
                        tabButton(for: tab)
                    }
                }
                .padding(6)
                .laxGlassCapsule()
                // One place for the haptic: putting it on each button fired
                // twice per switch (old tab leaving, new tab arriving).
                .sensoryFeedback(.selection, trigger: selectedTab)

                Button {
                    searchBounce += 1
                    onSearchTap()
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(LaxifyPalette.textPrimary)
                        .symbolEffect(.bounce, options: .nonRepeating, value: searchBounce)
                        .frame(width: LaxifyMetrics.searchButtonDiameter, height: LaxifyMetrics.searchButtonDiameter)
                        .laxGlassCircle(interactive: true)
                        // Re-declare the hit region: interactive glass otherwise
                        // eats taps that land off the glyph but inside the circle.
                        .contentShape(Circle())
                }
                .buttonStyle(TabPressStyle())
                .sensoryFeedback(.impact(weight: .light), trigger: searchBounce)
            }
        }
    }

    @ViewBuilder
    private func tabButton(for tab: AppTab) -> some View {
        let isSelected = selectedTab == tab
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                selectedTab = tab
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: tab.icon)
                    .font(.system(size: hideLabels ? 18 : 16, weight: .semibold))
                    // Replays whenever this tab becomes the selected one.
                    .symbolEffect(.bounce, options: .nonRepeating, value: isSelected)

                if isSelected && !hideLabels {
                    Text(L(tab.titleKey, tab.title))
                        .font(LaxifyTypography.tabLabel)
                        .lineLimit(1)
                        .fixedSize()
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
            .foregroundStyle(isSelected ? LaxifyPalette.textPrimary : LaxifyPalette.textTertiary)
            .padding(.horizontal, isSelected ? 16 : 12)
            .frame(height: LaxifyMetrics.tabBarHeight - 12)
            .background {
                if isSelected {
                    Capsule()
                        .fill(LaxifyPalette.surfaceElevated)
                        .matchedGeometryEffect(id: "tabSelection", in: selectionNamespace)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(TabPressStyle())
    }
}

/// A quick squash on press, springing back on release — the same feel the
/// player controls have, so the whole chrome responds to touch the same way.
private struct TabPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.55), value: configuration.isPressed)
    }
}
