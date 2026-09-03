import SwiftUI


/// Drop one or more tracks into a playlist — pick an existing one or make a
/// new one on the spot. Modelled on Apple Music's "Add to a Playlist": what
/// you're adding sits at the top, a clean "Новый плейлист" row, then the
/// playlists with a checkmark as each one takes the track.
struct AddToPlaylistSheet: View {
    let songs: [Song]
    var onDone: () -> Void

    var store = PlaylistStore.shared

    @State private var addedTo: Set<String> = []
    @State private var isCreatePresented = false
    @State private var newName = ""

    var body: some View {
        ZStack {

            VStack(spacing: 0) {
                header
                nowAdding

                ScrollView {
                    VStack(spacing: 10) {
                        newPlaylistRow

                        ForEach(store.playlists) { playlist in
                            row(playlist)
                        }

                        if store.playlists.isEmpty && !store.isLoading {
                            Text(L("playlist.addTo.empty", "Плейлистов пока нет — создайте первый"))
                                .font(LaxifyTypography.footnote)
                                .foregroundStyle(LaxifyPalette.textSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 20)
                        }
                    }
                    .padding(.horizontal, LaxifyMetrics.screenPadding)
                    .padding(.top, 8)
                    .padding(.bottom, 120)
                }
                .scrollIndicators(.hidden)
            }

            VStack {
                Spacer()
                doneButton
            }
        }
        .task { await store.loadIfNeeded() }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.regularMaterial)
        // A sheet on top of a sheet to type one word was the worst part of
        // this screen. The system's prompt takes the name and the playlist is
        // created with the track already in it.
        .alert(L("library.newPlaylist", "Новый плейлист"), isPresented: $isCreatePresented) {
            TextField(L("playlist.nameTitle", "Название плейлиста"), text: $newName)

            Button(L("common.cancel", "Отмена"), role: .cancel) { newName = "" }
            Button(L("playlist.create", "Создать")) {
                let title = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                newName = ""
                guard !title.isEmpty else { return }
                Task {
                    if let created = await store.create(title: title, isPublic: false, seed: songs) {
                        addedTo.insert(created.id)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Text(L("playlist.addTo", "В плейлист"))
                .font(.system(size: 22, weight: .heavy))
                .foregroundStyle(LaxifyPalette.textPrimary)

            Spacer()

            Button(action: onDone) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(LaxifyPalette.textPrimary)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .laxGlassCircle(interactive: true)
        }
        .padding(.horizontal, LaxifyMetrics.screenPadding)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    /// The track is the subject of this screen, so it is shown as one — big
    /// cover, centred, with its own name under it. The old version was a
    /// 40pt thumbnail in a corner, which read as a breadcrumb rather than as
    /// "this is the thing you are filing".
    @ViewBuilder
    private var nowAdding: some View {
        if let first = songs.first {
            VStack(spacing: 12) {
                AsyncCoverImage(url: first.coverURL, cornerRadius: 18, displaySize: 300)
                    .frame(width: 132, height: 132)
                    .shadow(color: .black.opacity(0.35), radius: 20, y: 10)

                VStack(spacing: 3) {
                    Text(songs.count == 1 ? first.title : "\(songs.count) \(PlaylistCard.tracksWord(songs.count))")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(LaxifyPalette.textPrimary)
                        .lineLimit(1)

                    if songs.count == 1 {
                        Text(first.artistName)
                            .font(.system(size: 13))
                            .foregroundStyle(LaxifyPalette.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, LaxifyMetrics.screenPadding)
            .padding(.bottom, 22)
        }
    }

    private var newPlaylistRow: some View {
        Button {
            isCreatePresented = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(LaxifyPalette.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                Text(L("library.newPlaylist", "Новый плейлист"))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(LaxifyPalette.textPrimary)

                Spacer()
            }
            .padding(10)
            .background(LaxifyPalette.surface, in: RoundedRectangle(cornerRadius: LaxifyMetrics.cardCornerRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func row(_ playlist: PlaylistDTO) -> some View {
        let added = addedTo.contains(playlist.id)
        return Button {
            add(to: playlist)
        } label: {
            HStack(spacing: 12) {
                thumb(playlist)

                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(LaxifyPalette.textPrimary)
                        .lineLimit(1)
                    Text("\(playlist.trackCount) \(PlaylistCard.tracksWord(playlist.trackCount))")
                        .font(LaxifyTypography.caption)
                        .foregroundStyle(LaxifyPalette.textSecondary)
                }

                Spacer()

                Image(systemName: added ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 22))
                    .foregroundStyle(added ? LaxifyPalette.accent : LaxifyPalette.textTertiary)
                    .contentTransition(.symbolEffect)
            }
            .padding(10)
            .background(LaxifyPalette.surface, in: RoundedRectangle(cornerRadius: LaxifyMetrics.cardCornerRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(added)
    }

    @ViewBuilder
    private func thumb(_ playlist: PlaylistDTO) -> some View {
        if let url = playlist.coverURL {
            AsyncCoverImage(url: url, cornerRadius: 12, displaySize: 104)
                .frame(width: 52, height: 52)
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LaxifyPalette.surfaceElevated)
                .frame(width: 52, height: 52)
                .overlay {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 18))
                        .foregroundStyle(LaxifyPalette.textTertiary)
                }
        }
    }

    private var doneButton: some View {
        Button(action: onDone) {
            Text(addedTo.isEmpty ? L("common.close", "Закрыть") : L("common.done", "Готово"))
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(LaxifyPalette.accent).interactive(), in: .capsule)
        .padding(.horizontal, LaxifyMetrics.screenPadding)
        .padding(.bottom, 16)
    }

    private func add(to playlist: PlaylistDTO) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            _ = addedTo.insert(playlist.id)
        }
        Task { await store.add(songs, to: playlist) }
    }
}
