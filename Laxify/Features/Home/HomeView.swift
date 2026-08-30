import SwiftUI

struct HomeView: View {
    @State private var viewModel = HomeViewModel()
    @State private var isSearchPresented = false
    @State private var isNotificationsPresented = false
    private var notifications = NotificationStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LaxifyMetrics.sectionSpacing) {
                topRow
                homeContent
            }
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .background(LaxifyPalette.background)
        .task {
            await viewModel.loadIfNeeded()
            await notifications.load()
        }
        .fullScreenCover(isPresented: $isSearchPresented) {
            SearchView { isSearchPresented = false }
        }
        .sheet(isPresented: $isNotificationsPresented) {
            NotificationsView { isNotificationsPresented = false }
        }
    }

    private var topRow: some View {
        HStack(spacing: 10) {
            searchField

            Button {
                isNotificationsPresented = true
            } label: {
                Image(systemName: "bell")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(LaxifyPalette.textPrimary)
                    .frame(width: LaxifyMetrics.searchButtonDiameter, height: LaxifyMetrics.searchButtonDiameter)
                    .laxGlassCircle(interactive: true)
                    .overlay(alignment: .topTrailing) {
                        if notifications.unreadCount > 0 {
                            Circle().fill(LaxifyPalette.accent)
                                .frame(width: 9, height: 9)
                                .offset(x: -6, y: 6)
                        }
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, LaxifyMetrics.screenPadding)
    }

    /// Opens the search screen — Home does not search inline any more, this is
    /// just the way in that people expect at the top of a music app.
    private var searchField: some View {
        Button {
            isSearchPresented = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(LaxifyPalette.textTertiary)
                Text(L("search.field", "Треки, артисты"))
                    .foregroundStyle(LaxifyPalette.textTertiary)
                Spacer()
            }
            .font(LaxifyTypography.body)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .laxGlassCapsule()
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var homeContent: some View {
        if let errorMessage = viewModel.errorMessage {
            VStack(alignment: .leading, spacing: 14) {
                Text(errorMessage)
                    .font(LaxifyTypography.body)
                    .foregroundStyle(LaxifyPalette.textSecondary)

                Button(L("common.retry", "Повторить")) {
                    Task { await viewModel.reload() }
                }
                .buttonStyle(.laxifySecondary)
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)
        } else if viewModel.isLoading && viewModel.content == nil {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
        } else if !viewModel.feed.isEmpty {
            ForEach(viewModel.feed) { block in
                FeedRow(block: block)
            }
        } else if viewModel.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
        } else {
            VStack(spacing: 14) {
                Text(L("home.empty", "Не удалось собрать ленту"))
                    .font(LaxifyTypography.body)
                    .foregroundStyle(LaxifyPalette.textSecondary)
                Button(L("common.retry", "Повторить")) {
                    Task { await viewModel.reload() }
                }
                .buttonStyle(.laxifySecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
        }
    }

}

#Preview {
    HomeView()
}
