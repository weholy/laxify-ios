import SwiftUI
import SwiftData

struct HomeView: View {
    @State private var viewModel = HomeViewModel()
    @State private var isSearchPresented = false
    @Query private var dislikedTracks: [DislikedTrack]

    private var recommendedTracks: [Song] {
        guard let content = viewModel.content else { return [] }
        let dislikedIds = Set(dislikedTracks.map(\.id))
        return content.recommendedTracks.filter { !dislikedIds.contains($0.id) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LaxifyMetrics.sectionSpacing) {
                searchField
                homeContent
            }
            .padding(.top, 12)
            .padding(.bottom, LaxifyMetrics.tabBarHeight + LaxifyMetrics.miniPlayerHeight + 40)
        }
        .background(LaxifyPalette.background)
        .task {
            await viewModel.loadIfNeeded()
        }
        .fullScreenCover(isPresented: $isSearchPresented) {
            SearchView { isSearchPresented = false }
        }
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
        .padding(.horizontal, LaxifyMetrics.screenPadding)
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
        } else if viewModel.content != nil {
            songCarousel(title: L("home.forYou", "Для вас"), songs: recommendedTracks)

            if recommendedTracks.count > 8 {
                trackListSection(title: L("home.more", "Ещё треки"), songs: Array(recommendedTracks.dropFirst(8)))
            }
        }
    }

    private func songCarousel(title: String, songs: [Song]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle(title)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: LaxifyMetrics.itemSpacing) {
                    ForEach(songs) { song in
                        Button {
                            AudioPlayerController.shared.play(song, queue: songs)
                        } label: {
                            SongCardView(song: song)
                        }
                        .buttonStyle(.plain)
                    }

                    // Reaching the end asks for more, so the row keeps going.
                    Color.clear
                        .frame(width: 1)
                        .onAppear {
                            Task { await viewModel.extendRecommendations() }
                        }
                }
                .padding(.horizontal, LaxifyMetrics.screenPadding)
            }
            .scrollClipDisabled()
        }
    }

    private func trackListSection(title: String, songs: [Song]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle(title)

            LazyVStack(spacing: 12) {
                ForEach(songs) { song in
                    Button {
                        AudioPlayerController.shared.play(song, queue: songs)
                    } label: {
                        SongRowView(song: song)
                    }
                    .buttonStyle(.plain)
                }

                if viewModel.isLoadingMore {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                } else {
                    Color.clear
                        .frame(height: 1)
                        .onAppear {
                            Task { await viewModel.extendRecommendations() }
                        }
                }
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(LaxifyTypography.title)
            .foregroundStyle(LaxifyPalette.textPrimary)
            .padding(.horizontal, LaxifyMetrics.screenPadding)
    }
}

#Preview {
    HomeView()
}
