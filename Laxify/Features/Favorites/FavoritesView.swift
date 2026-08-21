import SwiftUI

struct FavoritesView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LaxifyMetrics.sectionSpacing) {
                Text("Избранное")
                    .font(LaxifyTypography.largeTitle)
                    .foregroundStyle(LaxifyPalette.textPrimary)
                    .padding(.horizontal, LaxifyMetrics.screenPadding)
                    .padding(.top, 12)
            }
            .padding(.bottom, LaxifyMetrics.tabBarHeight + LaxifyMetrics.miniPlayerHeight + 40)
        }
        .background(LaxifyPalette.background)
    }
}

#Preview {
    FavoritesView()
}
