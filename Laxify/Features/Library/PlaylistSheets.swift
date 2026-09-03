import SwiftUI


/// Drop one or more tracks into a playlist — pick an existing one or make a
/// new one on the spot.
///
/// Deliberately the system's own furniture: a grouped `List` inside a
/// `NavigationStack`, standard rows, standard toolbar buttons. This screen is
/// a file-it-and-go interaction rather than somewhere to spend time, and the
/// version before this one dressed it up — a large cover, custom cards, a
/// glass button across the bottom — which made a two-second task look like a
/// destination. Nothing here is drawn by hand that iOS already draws.
struct AddToPlaylistSheet: View {
    let songs: [Song]
    var onDone: () -> Void

    var store = PlaylistStore.shared

    @State private var addedTo: Set<String> = []
    @State private var isCreatePresented = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        isCreatePresented = true
                    } label: {
                        Label(
                            L("library.newPlaylist", "Новый плейлист"),
                            systemImage: "plus.circle.fill"
                        )
                    }
                }

                Section {
                    ForEach(store.playlists) { playlist in
                        row(playlist)
                    }
                } header: {
                    if !store.playlists.isEmpty {
                        Text(L("library.playlists", "Плейлисты"))
                    }
                } footer: {
                    if store.playlists.isEmpty && !store.isLoading {
                        Text(L("playlist.addTo.empty", "Плейлистов пока нет — создайте первый"))
                    }
                }
            }
            .navigationTitle(subject)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(
                        addedTo.isEmpty
                            ? L("common.close", "Закрыть")
                            : L("common.done", "Готово"),
                        action: onDone
                    )
                }
            }
        }
        .task { await store.loadIfNeeded() }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
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

    /// What is being filed, in the title bar rather than as artwork: it is
    /// context for the choice, not the subject of the screen.
    private var subject: String {
        guard let first = songs.first else {
            return L("playlist.addTo", "В плейлист")
        }
        return songs.count == 1
            ? first.title
            : "\(songs.count) \(PlaylistCard.tracksWord(songs.count))"
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
                        .lineLimit(1)
                    Text("\(playlist.trackCount) \(PlaylistCard.tracksWord(playlist.trackCount))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if added {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                }
            }
            .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
        .disabled(added)
    }

    @ViewBuilder
    private func thumb(_ playlist: PlaylistDTO) -> some View {
        if let url = playlist.coverURL {
            AsyncCoverImage(url: url, cornerRadius: 6, displaySize: 88)
                .frame(width: 44, height: 44)
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.quaternary)
                .frame(width: 44, height: 44)
                .overlay {
                    Image(systemName: "music.note.list")
                        .foregroundStyle(.secondary)
                }
        }
    }

    private func add(to playlist: PlaylistDTO) {
        withAnimation { _ = addedTo.insert(playlist.id) }
        Task { await store.add(songs, to: playlist) }
    }
}
