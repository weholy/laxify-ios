import SwiftUI

struct AlbumDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let album: MusicAlbum

    @State private var songs: [Song] = []
    @State private var isLoading = false
    @State private var hasError = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LaxifyMetrics.sectionSpacing) {
                header
                actionButtons
                content
            }
            .padding(.bottom, LaxifyMetrics.miniPlayerHeight + 40)
        }
        .background(LaxifyPalette.background.ignoresSafeArea())
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "checkmark")
            }
            .buttonStyle(.laxifyCheckmark)
            .padding(.horizontal, LaxifyMetrics.screenPadding)
            .padding(.top, 12)
        }
        .task {
            await load()
        }
        .withMiniPlayer()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            AsyncCoverImage(url: album.coverURL, cornerRadius: LaxifyMetrics.cardCornerRadius)
                .frame(width: 200, height: 200)
                .shadow(color: .black.opacity(0.25), radius: 20, y: 10)
                .frame(maxWidth: .infinity, alignment: .center)

            VStack(alignment: .leading, spacing: 4) {
                Text(album.title)
                    .font(LaxifyTypography.largeTitle)
                    .foregroundStyle(LaxifyPalette.textPrimary)
                    .lineLimit(3)

                Text(subtitle)
                    .font(LaxifyTypography.footnote)
                    .foregroundStyle(LaxifyPalette.textSecondary)
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)
        }
        .padding(.top, 56)
    }

    private var subtitle: String {
        var parts: [String] = [album.artistName]
        if let year = album.year {
            parts.append(String(year))
        }
        if !songs.isEmpty {
            parts.append("\(songs.count) треков")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button {
                playAll(shuffled: false)
            } label: {
                Label("Слушать", systemImage: "play.fill")
            }
            .buttonStyle(.laxifyPrimary)

            Button {
                playAll(shuffled: true)
            } label: {
                Label("Перемешать", systemImage: "shuffle")
            }
            .buttonStyle(.laxifySecondary)
        }
        .disabled(songs.isEmpty)
        .opacity(songs.isEmpty ? 0.5 : 1)
        .padding(.horizontal, LaxifyMetrics.screenPadding)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && songs.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        } else if hasError {
            VStack(spacing: 14) {
                Text("Не удалось загрузить релиз")
                    .font(LaxifyTypography.body)
                    .foregroundStyle(LaxifyPalette.textSecondary)

                Button("Повторить") {
                    Task { await load(force: true) }
                }
                .buttonStyle(.laxifySecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
        } else {
            VStack(spacing: 12) {
                ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                    Button {
                        AudioPlayerController.shared.play(song, queue: songs)
                    } label: {
                        HStack(spacing: 12) {
                            Text("\(index + 1)")
                                .font(LaxifyTypography.footnote)
                                .foregroundStyle(LaxifyPalette.textTertiary)
                                .frame(width: 22, alignment: .trailing)

                            SongRowView(song: song)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)
        }
    }

    private func playAll(shuffled: Bool) {
        var queue = songs
        if shuffled { queue.shuffle() }
        guard let first = queue.first else { return }
        AudioPlayerController.shared.play(first, queue: queue)
    }

    private func load(force: Bool = false) async {
        guard force || songs.isEmpty, !isLoading else { return }
        isLoading = true
        hasError = false
        do {
            songs = try await YandexMusicService.shared.albumTracks(albumId: album.id)
        } catch {
            hasError = true
        }
        isLoading = false
    }
}
