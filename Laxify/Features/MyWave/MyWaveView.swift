import SwiftUI
import SwiftData

/// "Моя волна" — the artist fills the screen, the name sits over the photo,
/// and a deck of what's coming runs along the bottom above one big button.
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
    /// The card the deck holds in the middle — see `trackDeck`.
    @State private var centredCardId: String?

    private var focus: Song? {
        player.isPlayingWave ? player.currentSong : viewModel.tracks.first
    }

    private var deckSource: [Song] {
        player.isPlayingWave ? player.queue : viewModel.tracks
    }

    private var isFocusFavorite: Bool {
        guard let focus else { return false }
        return favorites.contains { $0.id == focus.id }
    }

    private var isFocusDisliked: Bool {
        guard let focus else { return false }
        return dislikedTracks.contains { $0.id == focus.id }
    }

    /// A window around what's playing: a few already-heard on the left, the
    /// current one, and what's queued on the right — so the deck reads as a
    /// place in a stream, not a list that starts at "now".
    private var windowed: [Song] {
        let source = deckSource
        guard !source.isEmpty else { return [] }

        if player.isPlayingWave {
            let index = player.currentIndex
            let lower = max(0, index - 3)
            let upper = min(source.count, index + 13)
            return Array(source[lower..<upper])
        }
        return Array(source.prefix(15))
    }

    var body: some View {
        ZStack {
            backdrop

            if deckSource.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    // Space above and below, so the deck sits in the middle of
                    // what is left rather than being pushed down by the photo.
                    Spacer(minLength: 0)
                    header.padding(.bottom, 20)
                    trackDeck.padding(.bottom, 40)
                    Spacer(minLength: 0)
                    controls
                }
                .padding(.horizontal, LaxifyMetrics.screenPadding)
                // Clear of the mini player, and no further. Ninety-six points
                // on top of it was over-corrected from an earlier version that
                // had them almost touching: it left the thumbs and the play
                // button stranded up in the middle of the screen, a long way
                // from where a thumb rests. Twenty-four keeps them off the
                // mini player and puts them back down within reach.
                .padding(.bottom, LaxifyMetrics.tabBarHeight + LaxifyMetrics.miniPlayerHeight + 24)
            }
        }
        .overlay(alignment: .topTrailing) {
            settingsButton
                .padding(.trailing, LaxifyMetrics.screenPadding)
                .padding(.top, 6)
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
                        CachedImage(url: url, displaySize: 600, contentMode: .fill)
                            .id(url)
                            .transition(.opacity)
                            // Sharp for a real photo, softened for a cover.
                            .blur(radius: viewModel.backdropIsArtistPhoto ? 3 : 22)
                            .scaleEffect(viewModel.backdropIsArtistPhoto ? 1.04 : 1.12)
                    } else {
                        palette.gradient
                    }
                }
            }
            .overlay {
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.05), location: 0),
                        .init(color: .black.opacity(0.12), location: 0.35),
                        .init(color: .black.opacity(0.55), location: 0.62),
                        .init(color: .black.opacity(0.96), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .overlay(alignment: .top) {
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 130)
            }
            .clipped()
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.7), value: viewModel.backdropURL)
    }

    private var settingsButton: some View {
        Button { isSettingsPresented = true } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .glassEffect(.regular, in: .circle)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            if viewModel.isLoading {
                ProgressView().tint(.white)
            } else {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 40))
                    .foregroundStyle(.white.opacity(0.6))
                Text(viewModel.errorMessage ?? L("wave.unavailable", "Волна пока недоступна"))
                    .font(LaxifyTypography.body)
                    .foregroundStyle(.white.opacity(0.7))
                Button(L("common.retry", "Повторить")) { Task { await viewModel.load() } }
                    .buttonStyle(.laxifySecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("wave.label", "МОЯ ВОЛНА"))
                .font(.system(size: 13, weight: .heavy))
                .tracking(2.5)
                .foregroundStyle(.white.opacity(0.75))

            Text(focus?.artistName ?? L("wave.default.artist", "Ваша волна"))
                .font(.system(size: 44, weight: .heavy))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.5)
                .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
                .contentTransition(.opacity)
                .animation(.spring(response: 0.5, dampingFraction: 0.85), value: focus?.artistName)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Which card the deck is centred on.
    ///
    /// Bound rather than scrolled to. Tapping a cover changes two things in
    /// the same update — the track that is current, and the window of cards
    /// built around its new index — and an imperative `scrollTo` fired from
    /// `onChange` ran against cards that had not been laid out yet. It did
    /// nothing, so the track played while the deck stayed where it was, which
    /// is exactly the fault: no way to see what is playing. A binding has no
    /// such ordering problem — SwiftUI keeps the named card centred once it
    /// exists, however the contents shifted to get there.
    private var trackDeck: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .center, spacing: 16) {
                ForEach(windowed, id: \.id) { song in
                    WaveTrackCard(
                        song: song,
                        isCurrent: song.id == focus?.id,
                        // Being the card in the middle and being the track
                        // coming out of the speaker are two different things:
                        // with anything else playing, the deck still focuses
                        // its first card, and that card used to claim to be
                        // playing while the mini player showed another song.
                        isPlaying: player.isPlayingWave && song.id == player.currentSong?.id
                    )
                    .id(song.id)
                    .onTapGesture { playFrom(song) }
                }
            }
            .scrollTargetLayout()
            // Enough slack that the first or last card can still sit near
            // the middle when it is the one playing.
            .padding(.horizontal, 96)
            .padding(.vertical, 6)
        }
        .scrollPosition(id: $centredCardId, anchor: .center)
        .scrollClipDisabled()
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: focus?.id)
        .onChange(of: focus?.id, initial: true) { _, id in
            guard let id, id != centredCardId else { return }
            withAnimation(.spring(response: 0.55, dampingFraction: 0.86)) {
                centredCardId = id
            }
        }
        .frame(height: 264)
    }

    private var controls: some View {
        HStack(spacing: 28) {
            circleButton(
                system: isFocusDisliked ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                tint: .white.opacity(0.9)
            ) { dislikeCurrent() }

            // Apple's play button does two things worth copying, and neither
            // is decoration: the glyph *replaces* rather than swaps, so the
            // change reads as one object changing state, and the whole button
            // squashes under the finger and springs back past its size. Both
            // make a press feel answered before any audio arrives.
            Button { togglePlay() } label: {
                Image(systemName: (player.isPlayingWave && player.isPlaying) ? "pause.fill" : "play.fill")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.black)
                    .contentTransition(.symbolEffect(.replace.downUp))
                    .frame(width: 80, height: 80)
                    .background(.white, in: Circle())
                    .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
            }
            .buttonStyle(SquashButtonStyle())
            .sensoryFeedback(.impact(weight: .medium), trigger: player.isPlaying)

            circleButton(
                system: isFocusFavorite ? "heart.fill" : "heart",
                tint: isFocusFavorite ? LaxifyPalette.accent : .white.opacity(0.9)
            ) { likeCurrent() }
        }
        .frame(maxWidth: .infinity)
    }

    private func circleButton(system: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 56, height: 56)
                .background(.white.opacity(0.14), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.14), lineWidth: 1))
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
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
            if let existing = favorites.first(where: { $0.id == song.id }) {
                modelContext.delete(existing)
                SyncService.shared.favoriteRemoved(trackId: song.id)
            } else {
                // Turning like on turns dislike off — smoothly, in the same
                // transaction, so the thumb un-fills as the heart fills.
                if let disliked = dislikedTracks.first(where: { $0.id == song.id }) {
                    modelContext.delete(disliked)
                }
                modelContext.insert(FavoriteTrack(song: song))
                SyncService.shared.favoriteAdded(song)
            }
        }
    }

    private func dislikeCurrent() {
        guard let song = focus else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
            if let disliked = dislikedTracks.first(where: { $0.id == song.id }) {
                // Already disliked — a second tap clears it.
                modelContext.delete(disliked)
            } else {
                if let favorite = favorites.first(where: { $0.id == song.id }) {
                    modelContext.delete(favorite)
                    SyncService.shared.favoriteRemoved(trackId: song.id)
                }
                modelContext.insert(DislikedTrack(id: song.id))
                SyncService.shared.dislikeAdded(trackId: song.id)
                if player.isPlayingWave {
                    player.skipAndReshapeWave()
                }
            }
        }
    }
}

/// One card in the deck. The current track is grown, ringed and badged; the
/// rest sit smaller and dimmed so the eye lands on what's playing.
private struct WaveTrackCard: View {
    let song: Song
    /// The card the deck holds in the middle.
    let isCurrent: Bool
    /// Whether this track is the one actually sounding.
    let isPlaying: Bool

    private var side: CGFloat { isCurrent ? 208 : 140 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncCoverImage(url: song.coverURL, cornerRadius: isCurrent ? 30 : 22, displaySize: 240)
                .frame(width: side, height: side)
                .overlay {
                    RoundedRectangle(cornerRadius: isCurrent ? 30 : 22, style: .continuous)
                        .stroke(.white.opacity(isCurrent ? 0.9 : 0), lineWidth: 2)
                }
                .overlay(alignment: .topLeading) {
                    if isPlaying {
                        Text(L("wave.nowPlaying", "Сейчас играет"))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(.white, in: Capsule())
                            .padding(10)
                    }
                }
                .shadow(color: .black.opacity(isCurrent ? 0.5 : 0.3), radius: isCurrent ? 22 : 12, y: 10)

            Text(song.title)
                .font(.system(size: isCurrent ? 15 : 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(song.artistName)
                .font(.system(size: isCurrent ? 13 : 12))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
        }
        .frame(width: side, alignment: .leading)
        .opacity(isCurrent ? 1 : 0.62)
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: isCurrent)
    }
}

#Preview {
    MyWaveView()
}
