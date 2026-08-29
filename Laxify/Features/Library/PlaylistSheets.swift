import SwiftUI

/// Name a new playlist and choose whether anyone can see it.
struct CreatePlaylistSheet: View {
    var onDone: () -> Void
    var seed: [Song] = []

    var store = PlaylistStore.shared

    @State private var name = ""
    @State private var isPublic = true
    @State private var isBusy = false
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            LaxifyPalette.background.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text(L("library.newPlaylist", "Новый плейлист"))
                        .font(.system(size: 26, weight: .heavy))
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

                TextField(L("playlist.nameTitle", "Название плейлиста"), text: $name)
                    .font(.system(size: 17))
                    .focused($focused)
                    .padding(16)
                    .background(LaxifyPalette.surface, in: RoundedRectangle(cornerRadius: LaxifyMetrics.groupedCornerRadius, style: .continuous))

                VStack(alignment: .leading, spacing: 7) {
                    Toggle(isOn: $isPublic) {
                        Text(L("playlist.public", "Открытый плейлист"))
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(LaxifyPalette.textPrimary)
                    }
                    .tint(LaxifyPalette.accent)
                    .padding(16)
                    .background(LaxifyPalette.surface, in: RoundedRectangle(cornerRadius: LaxifyMetrics.groupedCornerRadius, style: .continuous))

                    Text(L("playlist.public.sub", "Смогут увидеть другие по ссылке на ваш профиль"))
                        .font(.system(size: 12))
                        .foregroundStyle(LaxifyPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16)
                }

                if !seed.isEmpty {
                    Text("\(L("playlist.willAdd", "Будет добавлено треков")): \(seed.count)")
                        .font(LaxifyTypography.footnote)
                        .foregroundStyle(LaxifyPalette.textSecondary)
                }

                Spacer()

                Button {
                    create()
                } label: {
                    HStack(spacing: 8) {
                        if isBusy { ProgressView().tint(.white) }
                        Text(L("playlist.create", "Создать"))
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(LaxifyPalette.accent).interactive(), in: .capsule)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isBusy)
                .opacity(name.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)
            .padding(.top, 22)
            .padding(.bottom, 20)
        }
        .onAppear { focused = true }
    }

    private func create() {
        isBusy = true
        Task {
            _ = await store.create(title: name, isPublic: isPublic, seed: seed)
            isBusy = false
            onDone()
        }
    }
}

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

    var body: some View {
        ZStack {
            LaxifyPalette.background.ignoresSafeArea()

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
        .sheet(isPresented: $isCreatePresented) {
            CreatePlaylistSheet(onDone: {
                isCreatePresented = false
            }, seed: songs)
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

    /// What's being added — cover + title, or "N треков" for a batch.
    @ViewBuilder
    private var nowAdding: some View {
        if let first = songs.first {
            HStack(spacing: 12) {
                AsyncCoverImage(url: first.coverURL, cornerRadius: 10, displaySize: 84)
                    .frame(width: 40, height: 40)

                if songs.count == 1 {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(first.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(LaxifyPalette.textPrimary)
                            .lineLimit(1)
                        Text(first.artistName)
                            .font(.system(size: 12))
                            .foregroundStyle(LaxifyPalette.textSecondary)
                            .lineLimit(1)
                    }
                } else {
                    Text("\(songs.count) \(PlaylistCard.tracksWord(songs.count))")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(LaxifyPalette.textPrimary)
                }

                Spacer()
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)
            .padding(.bottom, 14)
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
            .background(LaxifyPalette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
            .background(LaxifyPalette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
