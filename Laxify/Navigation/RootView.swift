import SwiftUI

struct RootView: View {
    @State private var selectedTab: AppTab = .home
    @State private var isSearchPresented = false
    @State private var isPlayerPresented = false

    var body: some View {
        ZStack(alignment: .bottom) {
            LaxifyPalette.background.ignoresSafeArea()

            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 10) {
                MiniPlayerBar {
                    isPlayerPresented = true
                }

                LaxifyTabBar(selectedTab: $selectedTab) {
                    isSearchPresented = true
                }
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)
            .padding(.bottom, LaxifyMetrics.tabBarBottomInset)
        }
        .fullScreenCover(isPresented: $isSearchPresented) {
            SearchView()
        }
        .fullScreenCover(isPresented: $isPlayerPresented) {
            FullPlayerView()
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .home:
            HomeView()
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
