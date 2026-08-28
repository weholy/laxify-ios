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
        NavigationStack {
            Form {
                Section {
                    TextField("Название", text: $name)
                        .focused($focused)
                }

                Section {
                    Toggle("Открытый плейлист", isOn: $isPublic)
                } footer: {
                    Text("Открытый плейлист смогут увидеть другие по ссылке на ваш профиль.")
                }

                if !seed.isEmpty {
                    Section {
                        Text("Будет добавлено треков: \(seed.count)")
                            .foregroundStyle(LaxifyPalette.textSecondary)
                    }
                }
            }
            .navigationTitle("Новый плейлист")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена", action: onDone)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Создать") { create() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isBusy)
                }
            }
            .onAppear { focused = true }
        }
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
/// new one on the spot. Used from the player overflow and a track long-press.
struct AddToPlaylistSheet: View {
    let songs: [Song]
    var onDone: () -> Void

    var store = PlaylistStore.shared

    @State private var addedTo: Set<String> = []
    @State private var isCreatePresented = false

    var body: some View {
        NavigationStack {
            List {
                Button {
                    isCreatePresented = true
                } label: {
                    Label("Новый плейлист", systemImage: "plus.circle.fill")
                        .foregroundStyle(LaxifyPalette.accent)
                }

                ForEach(store.playlists) { playlist in
                    Button {
                        add(to: playlist)
                    } label: {
                        HStack(spacing: 12) {
                            playlistThumb(playlist)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(playlist.title)
                                    .foregroundStyle(LaxifyPalette.textPrimary)
                                    .lineLimit(1)
                                Text("\(playlist.trackCount) \(PlaylistCard.tracksWord(playlist.trackCount))")
                                    .font(LaxifyTypography.caption)
                                    .foregroundStyle(LaxifyPalette.textSecondary)
                            }
                            Spacer()
                            if addedTo.contains(playlist.id) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(LaxifyPalette.accent)
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
                    }
                    .disabled(addedTo.contains(playlist.id))
                }
            }
            .listStyle(.plain)
            .navigationTitle(songs.count == 1 ? "В плейлист" : "Добавить \(songs.count) треков")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово", action: onDone)
                }
            }
            .task { await store.loadIfNeeded() }
            .sheet(isPresented: $isCreatePresented) {
                CreatePlaylistSheet(onDone: { isCreatePresented = false }, seed: songs)
            }
        }
    }

    @ViewBuilder
    private func playlistThumb(_ playlist: PlaylistDTO) -> some View {
        if let url = playlist.coverURL {
            AsyncCoverImage(url: url, cornerRadius: 10, displaySize: 44)
                .frame(width: 40, height: 40)
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LaxifyPalette.surface)
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 15))
                        .foregroundStyle(LaxifyPalette.textTertiary)
                }
        }
    }

    private func add(to playlist: PlaylistDTO) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            _ = addedTo.insert(playlist.id)
        }
        Task { await store.add(songs, to: playlist) }
    }
}
