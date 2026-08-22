import SwiftUI

struct PlaylistDetailView: View {
    @State private var viewModel: PlaylistDetailViewModel
    private let onClose: () -> Void

    init(collection: MusicCollection, onClose: @escaping () -> Void) {
        self.onClose = onClose
        _viewModel = State(initialValue: PlaylistDetailViewModel(collection: collection))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LaxifyMetrics.sectionSpacing) {
                header

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(LaxifyTypography.body)
                        .foregroundStyle(LaxifyPalette.textSecondary)
                } else if viewModel.isLoading && viewModel.songs.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else {
                    VStack(spacing: 12) {
                        ForEach(viewModel.songs) { song in
                            Button {
                                AudioPlayerController.shared.play(song, queue: viewModel.songs)
                            } label: {
                                SongRowView(song: song)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)
            .padding(.top, 12)
            .padding(.bottom, LaxifyMetrics.miniPlayerHeight + 40)
        }
        .background(LaxifyPalette.background.ignoresSafeArea())
        .task {
            await viewModel.loadIfNeeded()
        }
        .withMiniPlayer()
    }

    private var header: some View {
        HStack {
            Text(viewModel.title)
                .font(LaxifyTypography.largeTitle)
                .foregroundStyle(LaxifyPalette.textPrimary)
                .lineLimit(2)

            Spacer()

            LaxifyCloseButton(action: onClose)
        }
    }
}
