import SwiftUI

struct AlbumDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let album: MusicAlbum

    @State private var loadedAlbum: MusicAlbum?
    @State private var songs: [Song] = []
    @State private var isLoading = false
    @State private var hasError = false

    private var displayed: MusicAlbum { loadedAlbum ?? album }

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
        VStack(spacing: 16) {
            AsyncCoverImage(url: displayed.coverURL, cornerRadius: 24)
                .frame(width: 210, height: 210)
                .shadow(color: .black.opacity(0.3), radius: 24, y: 12)

            VStack(spacing: 6) {
                Text(displayed.title)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(LaxifyPalette.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)

                Text(subtitle)
                    .font(LaxifyTypography.footnote)
                    .foregroundStyle(LaxifyPalette.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 56)
    }

    private var subtitle: String {
        var parts: [String] = [displayed.artistName]
        if let year = displayed.year {
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
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.laxifyPrimary)

            Button {
                playAll(shuffled: true)
            } label: {
                Label("Перемешать", systemImage: "shuffle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.laxifySecondary)

            ShareLink(item: ShareText.album(displayed)) {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.laxifyIcon)
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
            let detail = try await YandexMusicService.shared.albumDetail(albumId: album.id)
            loadedAlbum = detail.album
            songs = detail.songs
        } catch {
            hasError = true
        }
        isLoading = false
    }
}
