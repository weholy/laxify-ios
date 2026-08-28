import SwiftUI
import SwiftData

/// "Моя волна" — a full-bleed station screen: the artist behind everything, a
/// deck of what's coming, and one big button. Whatever the player is on, if it
/// belongs to the wave, this screen follows it.
struct MyWaveView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var favorites: [FavoriteTrack]
    @Query private var dislikedTracks: [DislikedTrack]

    @State private var viewModel = MyWaveViewModel()
    var player = AudioPlayerController.shared
    @State private var isSettingsPresented = false
    @State private var palette: ArtworkPalette = .neutral

    /// The track the screen centres on: the player's, when it is playing the
    /// wave; otherwise the head of the queue.
    private var focus: Song? {
        if let current = player.currentSong,
           viewModel.tracks.contains(where: { $0.id == current.id }) {
            return current
        }
        return viewModel.tracks.first
    }

    private var isPlayingWave: Bool {
        guard let current = player.currentSong else { return false }
        return viewModel.tracks.contains { $0.id == current.id }
    }

    private var upcoming: [Song] {
        guard let focus,
              let index = viewModel.tracks.firstIndex(where: { $0.id == focus.id }) else {
            return Array(viewModel.tracks.prefix(10))
        }
        return Array(viewModel.tracks[index...].prefix(12))
    }

    var body: some View {
        ZStack {
            backdrop
            content
        }
        .task { await viewModel.loadIfNeeded() }
        .task(id: focus?.id) {
            await viewModel.updateBackdrop(for: focus)

            // Keep a few tracks of headroom under the deck.
            if let focus,
               let index = viewModel.tracks.firstIndex(where: { $0.id == focus.id }),
               index >= viewModel.tracks.count - 4 {
                await viewModel.extend()
            }
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
        if viewModel.tracks.isEmpty {
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
        VStack(alignment: .leading, spacing: 6) {
            Text("МОЯ ВОЛНА")
                .font(.system(size: 13, weight: .heavy))
                .tracking(2)
                .foregroundStyle(.white.opacity(0.7))

            Text(focus?.artistName ?? "Ваша волна")
                .font(.system(size: 40, weight: .heavy))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.55)
                .contentTransition(.opacity)
                .animation(.spring(response: 0.5, dampingFraction: 0.85), value: focus?.artistName)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var trackDeck: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(Array(upcoming.enumerated()), id: \.element.id) { index, song in
                    WaveTrackCard(song: song, isCurrent: index == 0 && isPlayingWave)
                        .onTapGesture { playFrom(song) }
                }
            }
            .padding(.vertical, 10)
        }
        .scrollClipDisabled()
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: focus?.id)
    }

    private var controls: some View {
        HStack(spacing: 22) {
            circleButton(system: "hand.thumbsdown", size: 52) { dislikeCurrent() }

            Button { togglePlay() } label: {
                Image(systemName: (isPlayingWave && player.isPlaying) ? "pause.fill" : "play.fill")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 76, height: 76)
                    .background(.white, in: Circle())
                    .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.impact(weight: .medium), trigger: isPlayingWave && player.isPlaying)

            circleButton(system: "slider.horizontal.3", size: 52) { isSettingsPresented = true }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
    }

    private func circleButton(system: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: size, height: size)
                .background(.white.opacity(0.12), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func togglePlay() {
        if isPlayingWave {
            player.togglePlayPause()
        } else if let start = focus ?? viewModel.tracks.first {
            player.play(start, queue: viewModel.tracks, waveBatchId: viewModel.batchId)
        }
    }

    private func playFrom(_ song: Song) {
        player.play(song, queue: viewModel.tracks, waveBatchId: viewModel.batchId)
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
        if isPlayingWave, player.hasNext {
            player.next()
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
