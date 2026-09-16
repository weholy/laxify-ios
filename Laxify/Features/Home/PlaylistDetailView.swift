import SwiftUI

struct PlaylistDetailView: View {
    @State private var viewModel: PlaylistDetailViewModel
    private let onClose: () -> Void

    init(collection: MusicCollection, onClose: @escaping () -> Void) {
        self.onClose = onClose
        _viewModel = State(initialValue: PlaylistDetailViewModel(collection: collection))
    }

    var body: some View {
        // The header sits outside the scroll view, the way the profile and
        // settings screens already do it: layered over one, its button caught
        // only the taps the scroll gesture did not want first.
        VStack(spacing: 0) {
            header
                .padding(.horizontal, LaxifyMetrics.screenPadding)
                .padding(.top, 12)
                .padding(.bottom, 8)

            scrollBody
        }
        .background(LaxifyPalette.background.ignoresSafeArea())
        .task {
            await viewModel.loadIfNeeded()
        }
        .withMiniPlayer()
    }

    private var scrollBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LaxifyMetrics.sectionSpacing) {
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
                            .trackContextMenu(song: song)
                        }
                    }
                }
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)
            .padding(.top, 12)
            .padding(.bottom, LaxifyMetrics.miniPlayerHeight + 40)
        }
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
