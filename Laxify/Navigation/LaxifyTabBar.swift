import SwiftUI

struct LaxifyTabBar: View {
    @Binding var selectedTab: AppTab
    var onSearchTap: () -> Void

    @Namespace private var selectionNamespace

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

                Button(action: onSearchTap) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(LaxifyPalette.textPrimary)
                        .frame(width: LaxifyMetrics.searchButtonDiameter, height: LaxifyMetrics.searchButtonDiameter)
                }
                .laxGlassCircle(interactive: true)
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
                    .font(.system(size: 16, weight: .semibold))
                if isSelected {
                    Text(tab.title)
                        .font(LaxifyTypography.tabLabel)
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
        }
        .buttonStyle(.plain)
    }
}
