import SwiftUI
import SwiftData

/// Everything kept on the device, as its own list.
///
/// Behaves like a playlist you can play, shuffle and empty — the difference
/// being that emptying it takes the files with it, which is the whole reason
/// the screen exists.
struct DownloadsView: View {
    var onBack: () -> Void

    @Query(sort: \DownloadedTrack.savedAt, order: .reverse) private var tracks: [DownloadedTrack]
    var downloads = DownloadManager.shared

    @State private var showsClear = false

    var body: some View {
        ZStack {
            LaxifyPalette.background.ignoresSafeArea()

            VStack(spacing: 0) {
                SettingsHeader(title: L("downloads.title", "Скачано"), onBack: onBack)

                if tracks.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
        }
        .confirmationDialog(
            L("downloads.clearConfirm", "Удалить все загрузки?"),
            isPresented: $showsClear,
            titleVisibility: .visible
        ) {
            Button(L("common.delete", "Удалить"), role: .destructive) {
                downloads.removeAll()
            }
            Button(L("common.cancel", "Отмена"), role: .cancel) {}
        } message: {
            Text(L("downloads.clearNote", "Файлы будут стёрты с устройства. Сами треки останутся в приложении"))
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LaxifyMetrics.sectionSpacing) {
                header

                VStack(spacing: 12) {
                    ForEach(tracks) { track in
                        SongRowView(song: track.song)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                AudioPlayerController.shared.play(
                                    track.song, queue: tracks.map(\.song)
                                )
                            }
                            .trackContextMenu(song: track.song)
                    }
                }
                .padding(.horizontal, LaxifyMetrics.screenPadding)
            }
            .padding(.top, 4)
            .padding(.bottom, 120)
        }
    }

    private var header: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Text("\(tracks.count) \(LibraryView.tracksWord(tracks.count))")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(LaxifyPalette.textPrimary)

                Text(sizeOnDisk)
                    .font(LaxifyTypography.footnote)
                    .foregroundStyle(LaxifyPalette.textSecondary)
            }

            HStack(spacing: 10) {
                Button {
                    play(shuffled: false)
                } label: {
                    Label(L("favorites.listen", "Слушать"), systemImage: "play.fill")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.laxifyPrimary)

                Button {
                    play(shuffled: true)
                } label: {
                    Label(L("favorites.shuffle", "Перемешать"), systemImage: "shuffle")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.laxifySecondary)
            }

            Button(role: .destructive) {
                showsClear = true
            } label: {
                Text(L("downloads.clear", "Удалить все загрузки"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .glassEffect(.regular.tint(.red.opacity(0.12)).interactive(), in: .capsule)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, LaxifyMetrics.screenPadding)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 40))
                .foregroundStyle(LaxifyPalette.textTertiary)
            Text(L("downloads.empty", "Здесь появятся треки, которые вы скачали"))
                .font(LaxifyTypography.footnote)
                .foregroundStyle(LaxifyPalette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sizeOnDisk: String {
        let bytes = tracks.reduce(0) { $0 + $1.byteCount }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private func play(shuffled: Bool) {
        var songs = tracks.map(\.song)
        if shuffled { songs.shuffle() }
        guard let first = songs.first else { return }
        AudioPlayerController.shared.play(first, queue: songs)
    }
}
