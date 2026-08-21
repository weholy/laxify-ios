import SwiftUI

struct PlaylistDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: PlaylistDetailViewModel

    init(collection: MusicCollection) {
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
                            SongRowView(song: song)
                        }
                    }
                }
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
        .background(LaxifyPalette.background.ignoresSafeArea())
        .task {
            await viewModel.loadIfNeeded()
        }
    }

    private var header: some View {
        HStack {
            Text(viewModel.title)
                .font(LaxifyTypography.largeTitle)
                .foregroundStyle(LaxifyPalette.textPrimary)
                .lineLimit(2)

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "checkmark")
            }
            .buttonStyle(.laxifyCheckmark)
        }
    }
}
