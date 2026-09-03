import SwiftUI
import PhotosUI

/// One of the account's own playlists: a collage header, play controls, the
/// tracks with swipe-to-remove, and an overflow to rename, flip visibility or
/// delete it.
struct UserPlaylistView: View {
    let playlist: PlaylistDTO
    var onClose: () -> Void

    var store = PlaylistStore.shared
    var covers = PlaylistCoverStore.shared

    @State private var detail: PlaylistDetailDTO?
    @State private var isLoading = true
    @State private var songs: [Song] = []

    @State private var isRenaming = false
    @State private var draftName = ""
    @State private var showDeleteConfirm = false
    @State private var coverPick: PhotosPickerItem?
    @State private var isCoverPickerPresented = false

    var downloads = DownloadManager.shared
    var player = AudioPlayerController.shared

    private var title: String { detail?.title ?? playlist.title }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LaxifyMetrics.sectionSpacing) {
                header

                if isLoading && songs.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else if songs.isEmpty {
                    Text(L("playlist.empty", "В этом плейлисте пока нет треков"))
                        .font(LaxifyTypography.body)
                        .foregroundStyle(LaxifyPalette.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 30)
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(songs) { song in
                            SongRowView(song: song)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    AudioPlayerController.shared.play(song, queue: songs)
                                }
                                .trackContextMenu(
                                    song: song,
                                    removeTitle: L("playlist.removeTrack", "Убрать из плейлиста")
                                ) {
                                    remove(song)
                                }
                        }
                    }
                }
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)
            .padding(.top, 12)
            .padding(.bottom, LaxifyMetrics.miniPlayerHeight + 40)
        }
        .background(LaxifyPalette.background.ignoresSafeArea())
        .task { await load() }
        .onChange(of: coverPick) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    covers.set(data, for: playlist.id)
                }
                coverPick = nil
            }
        }
        .photosPicker(isPresented: $isCoverPickerPresented, selection: $coverPick, matching: .images)
        .withMiniPlayer()
        .alert(L("playlist.nameTitle", "Название плейлиста"), isPresented: $isRenaming) {
            TextField(L("playlist.nameTitle", "Название плейлиста"), text: $draftName)
            Button(L("common.save", "Сохранить")) {
                Task { await store.rename(playlist, to: draftName) }
            }
            Button(L("common.cancel", "Отмена"), role: .cancel) {}
        }
        .confirmationDialog("\(L("playlist.delete", "Удалить плейлист")) «\(title)»?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button(L("common.delete", "Удалить"), role: .destructive) {
                Task {
                    await store.delete(playlist)
                    onClose()
                }
            }
            Button(L("common.cancel", "Отмена"), role: .cancel) {}
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                LaxifyCloseButton(style: .chevronDown, tinted: false, action: onClose)

                Spacer()

                Menu {
                    Button {
                        draftName = title
                        isRenaming = true
                    } label: {
                        Label(L("playlist.rename", "Переименовать"), systemImage: "pencil")
                    }

                    // A PhotosPicker nested inside a Menu never presents —
                    // the menu dismisses before the picker can take over. The
                    // button only raises a flag; the picker hangs off the view.
                    Button {
                        isCoverPickerPresented = true
                    } label: {
                        Label(L("playlist.cover", "Обложка"), systemImage: "photo")
                    }

                    if covers.image(for: playlist.id) != nil {
                        Button(role: .destructive) {
                            covers.clear(for: playlist.id)
                        } label: {
                            Label(L("playlist.cover.remove", "Убрать обложку"), systemImage: "photo.badge.minus")
                        }
                    }

                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label(L("playlist.delete", "Удалить плейлист"), systemImage: "trash")
                    }
                } label: {
                    // Same size and same material as the collapse chevron
                    // opposite it — they are a pair, and they read as one.
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(LaxifyPalette.textPrimary)
                        .frame(width: 46, height: 46)
                        .glassEffect(.regular, in: .circle)
                        .contentShape(Circle())
                }
            }

            collage
                .frame(width: 200, height: 200)
                .clipShape(RoundedRectangle(cornerRadius: LaxifyMetrics.cardCornerRadius, style: .continuous))
                .shadow(color: .black.opacity(0.3), radius: 22, y: 12)
                .frame(maxWidth: .infinity)

            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(LaxifyPalette.textPrimary)
                    .multilineTextAlignment(.center)
                Text("\(songs.count) \(PlaylistCard.tracksWord(songs.count))")
                    .font(LaxifyTypography.footnote)
                    .foregroundStyle(LaxifyPalette.textSecondary)
            }
            .frame(maxWidth: .infinity)

            // The same three glyphs as favourites, and for the same reason:
            // with the words gone the row reads as one control with a centre.
            HStack(spacing: 22) {
                CircleGlassButton(
                    systemImage: "shuffle",
                    diameter: 52,
                    accessibilityLabel: L("playlist.shuffle", "Перемешать")
                ) {
                    var shuffled = songs
                    shuffled.shuffle()
                    guard let first = shuffled.first else { return }
                    AudioPlayerController.shared.play(first, queue: shuffled)
                }
                .disabled(songs.isEmpty)
                .opacity(songs.isEmpty ? 0.4 : 1)

                CircleGlassButton(
                    systemImage: isPlayingHere ? "pause.fill" : "play.fill",
                    diameter: 66,
                    glyphSize: 24,
                    tint: LaxifyPalette.accent,
                    accessibilityLabel: isPlayingHere
                        ? L("player.pause", "Пауза")
                        : L("playlist.listen", "Слушать")
                ) { playOrPause() }
                .disabled(songs.isEmpty)
                .opacity(songs.isEmpty ? 0.4 : 1)

                DownloadRingButton(
                    progress: downloads.batchProgress,
                    isDone: !songs.isEmpty && songs.allSatisfy { downloads.isDownloaded($0.id) },
                    action: { downloads.download(songs) }
                )
                .disabled(songs.isEmpty)
                .opacity(songs.isEmpty ? 0.4 : 1)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// Whether what is playing came from this playlist.
    private var isPlayingHere: Bool {
        guard player.isPlaying, let current = player.currentSong else { return false }
        return songs.contains { $0.id == current.id }
    }

    private func playOrPause() {
        if let current = player.currentSong, songs.contains(where: { $0.id == current.id }) {
            player.togglePlayPause()
        } else if let first = songs.first {
            player.play(first, queue: songs)
        }
    }
    @ViewBuilder
    private var collage: some View {
        if let custom = covers.image(for: playlist.id) {
            Image(uiImage: custom).resizable().scaledToFill()
        } else {
            defaultCollage
        }
    }

    @ViewBuilder
    private var defaultCollage: some View {
        let urls = Array(songs.compactMap(\.coverURL).prefix(4))
        if urls.count >= 4 {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 0), GridItem(.flexible(), spacing: 0)], spacing: 0) {
                ForEach(0..<4, id: \.self) { index in
                    AsyncCoverImage(url: urls[index], cornerRadius: 0, displaySize: 100)
                        .aspectRatio(1, contentMode: .fill)
                        .clipped()
                }
            }
        } else if let first = urls.first {
            AsyncCoverImage(url: first, cornerRadius: 0, displaySize: 200)
        } else {
            let seed = playlist.id.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
            let hue = Double(seed % 360) / 360
            LinearGradient(
                colors: [
                    Color(hue: hue, saturation: 0.55, brightness: 0.8),
                    Color(hue: (hue + 0.1).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.45)
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .overlay {
                Image(systemName: "music.note.list")
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        guard let fresh = try? await LaxifyAPI.shared.playlist(id: playlist.id) else { return }
        detail = fresh
        songs = fresh.songs
    }

    private func remove(_ song: Song) {
        songs.removeAll { $0.id == song.id }
        Task { await store.removeTrack(song.id, from: playlist.id) }
    }
}
