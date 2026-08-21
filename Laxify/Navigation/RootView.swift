import SwiftUI

struct RootView: View {
    @State private var selectedTab: AppTab = .home
    @State private var isSearchPresented = false

    var body: some View {
        ZStack(alignment: .bottom) {
            LaxifyPalette.background.ignoresSafeArea()

            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            LaxifyTabBar(selectedTab: $selectedTab) {
                isSearchPresented = true
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)
            .padding(.bottom, LaxifyMetrics.tabBarBottomInset)
        }
        .fullScreenCover(isPresented: $isSearchPresented) {
            SearchView()
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .home:
            HomeView(onSearchTap: { isSearchPresented = true })
        case .favorites:
            FavoritesView()
        case .profile:
            ProfileView()
        }
    }
}

#Preview {
    RootView()
}
