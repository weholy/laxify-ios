import SwiftUI
import SwiftData

/// "Моя волна" — a full-bleed station screen: the artist behind everything, a
/// deck of what's coming, and one big button.
///
/// The station itself lives in `AudioPlayerController` (so it keeps going from
/// the mini player too); this screen mirrors that live queue and feeds it
/// thumbs and settings the way Yandex's wave does.
struct MyWaveView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var favorites: [FavoriteTrack]
    @Query private var dislikedTracks: [DislikedTrack]

    @State private var viewModel = MyWaveViewModel()
    var player = AudioPlayerController.shared
    @State private var isSettingsPresented = false
    @State private var palette: ArtworkPalette = .neutral

    /// The track the screen centres on: the player's, when it is playing the
    /// wave; otherwise the head of the preview.
    private var focus: Song? {
        player.isPlayingWave ? player.currentSong : viewModel.tracks.first
    }

    /// What the deck is built from — the live player queue once the wave is
    /// playing, the preview batch before that.
    private var deckSource: [Song] {
        player.isPlayingWave ? player.queue : viewModel.tracks
    }

    private var isFocusFavorite: Bool {
        guard let focus else { return false }
        return favorites.contains { $0.id == focus.id }
    }

    private var upcoming: [Song] {
        let source = deckSource
        guard let focus, let index = source.firstIndex(where: { $0.id == focus.id }) else {
            return Array(source.prefix(12))
        }
        return Array(source[index...].prefix(14))
    }

    var body: some View {
        ZStack {
            backdrop
            content
        }
        .task { await viewModel.loadIfNeeded() }
        .task(id: focus?.id) {
            await viewModel.updateBackdrop(for: focus)
        }
        .task(id: viewModel.backdropURL) {
            palette = await PaletteExtractor.shared.palette(for: viewModel.backdropURL)
        }
        .sheet(isPresented: $isSettingsPresented) {
            WaveSettingsView(
                settings: viewModel.settings,
                onApply: { updated in Task { await viewModel.apply(updated) } },
                onClose: { isSettingsPresented = false }
            )
        }
    }

    // MARK: - Backdrop

    private var backdrop: some View {
        Color.black
            .overlay {
                Group {
                    if let url = viewModel.backdropURL {
                        CachedImage(url: url, displaySize: 320, contentMode: .fill)
                            .id(url)
                            .transition(.opacity)
                            .blur(radius: 36)
                            .scaleEffect(1.15)
                    } else {
                        palette.gradient
                    }
                }
            }
            .overlay {
                LinearGradient(
                    colors: [.black.opacity(0.2), .black.opacity(0.3), .black.opacity(0.9)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .clipped()
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.6), value: viewModel.backdropURL)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if deckSource.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                header
                Spacer(minLength: 12)
                trackDeck
                controls
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)
            .padding(.top, 12)
            .padding(.bottom, LaxifyMetrics.tabBarHeight + LaxifyMetrics.miniPlayerHeight + 24)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            if viewModel.isLoading {
                ProgressView().tint(.white)
            } else {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 40))
                    .foregroundStyle(.white.opacity(0.6))
                Text(viewModel.errorMessage ?? "Волна пока недоступна")
                    .font(LaxifyTypography.body)
                    .foregroundStyle(.white.opacity(0.7))
                Button("Повторить") { Task { await viewModel.load() } }
                    .buttonStyle(.laxifySecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("МОЯ ВОЛНА")
                    .font(.system(size: 13, weight: .heavy))
                    .tracking(2)
                    .foregroundStyle(.white.opacity(0.7))

                Text(focus?.artistName ?? "Ваша волна")
                    .font(.system(size: 38, weight: .heavy))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.55)
                    .contentTransition(.opacity)
                    .animation(.spring(response: 0.5, dampingFraction: 0.85), value: focus?.artistName)
            }

            Spacer()

            Button { isSettingsPresented = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.14), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var trackDeck: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(Array(upcoming.enumerated()), id: \.element.id) { index, song in
                    WaveTrackCard(song: song, isCurrent: index == 0 && player.isPlayingWave)
                        .onTapGesture { playFrom(song) }
                }
            }
            .padding(.vertical, 10)
        }
        .scrollClipDisabled()
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: focus?.id)
    }

    private var controls: some View {
        HStack(spacing: 26) {
            circleButton(
                system: "hand.thumbsdown\(isFocusDisliked ? ".fill" : "")",
                tint: .white.opacity(0.85)
            ) { dislikeCurrent() }

            Button { togglePlay() } label: {
                Image(systemName: (player.isPlayingWave && player.isPlaying) ? "pause.fill" : "play.fill")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 76, height: 76)
                    .background(.white, in: Circle())
                    .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.impact(weight: .medium), trigger: player.isPlaying)

            circleButton(
                system: isFocusFavorite ? "heart.fill" : "heart",
                tint: isFocusFavorite ? LaxifyPalette.accent : .white.opacity(0.85)
            ) { likeCurrent() }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
    }

    private var isFocusDisliked: Bool {
        guard let focus else { return false }
        return dislikedTracks.contains { $0.id == focus.id }
    }

    private func circleButton(system: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 54, height: 54)
                .background(.white.opacity(0.12), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.12), lineWidth: 1))
                .contentTransition(.symbolEffect)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func togglePlay() {
        if player.isPlayingWave {
            player.togglePlayPause()
            return
        }
        Task {
            if viewModel.batchId == nil { await viewModel.load() }
            guard let start = viewModel.tracks.first else { return }
            player.play(start, queue: viewModel.tracks, waveBatchId: viewModel.batchId)
        }
    }

    private func playFrom(_ song: Song) {
        if player.isPlayingWave, let index = player.queue.firstIndex(where: { $0.id == song.id }) {
            player.playIndex(index)
        } else {
            player.play(song, queue: viewModel.tracks, waveBatchId: viewModel.batchId)
        }
    }

    private func likeCurrent() {
        guard let song = focus else { return }
        if let existing = favorites.first(where: { $0.id == song.id }) {
            modelContext.delete(existing)
            SyncService.shared.favoriteRemoved(trackId: song.id)
        } else {
            modelContext.insert(FavoriteTrack(song: song))
            SyncService.shared.favoriteAdded(song)
        }
    }

    private func dislikeCurrent() {
        guard let song = focus else { return }
        if !dislikedTracks.contains(where: { $0.id == song.id }) {
            modelContext.insert(DislikedTrack(id: song.id))
            SyncService.shared.dislikeAdded(trackId: song.id)
        }
        if let favorite = favorites.first(where: { $0.id == song.id }) {
            modelContext.delete(favorite)
            SyncService.shared.favoriteRemoved(trackId: song.id)
        }
        if player.isPlayingWave {
            player.skipAndReshapeWave()
        }
    }
}

private struct WaveTrackCard: View {
    let song: Song
    let isCurrent: Bool

    private var side: CGFloat { isCurrent ? 190 : 150 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncCoverImage(url: song.coverURL, cornerRadius: 28, displaySize: 220)
                .frame(width: side, height: side)
                .shadow(color: .black.opacity(0.4), radius: 16, y: 10)
                .overlay(alignment: .topLeading) {
                    if isCurrent {
                        Text("Сейчас играет")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.white, in: Capsule())
                            .padding(10)
                    }
                }

            Text(song.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(song.artistName)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(1)
        }
        .frame(width: side, alignment: .leading)
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: isCurrent)
    }
}

#Preview {
    MyWaveView()
}
