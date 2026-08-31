import SwiftUI
import SwiftData

struct LyricsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var favorites: [FavoriteTrack]

    var player = AudioPlayerController.shared
    @State private var viewModel = LyricsViewModel()

    /// Reader-set line size, remembered across sessions. Multiplies the base
    /// sizes below rather than replacing them, so the synced/plain hierarchy
    /// stays intact at every step.
    @AppStorage("laxify.lyrics.fontScale") private var fontScale = 1.0

    private var isFavorite: Bool {
        guard let song = player.currentSong else { return false }
        return favorites.contains { $0.id == song.id }
    }

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                header
                content
            }
        }
        .task(id: player.currentSong?.id) {
            guard let song = player.currentSong else { return }
            await viewModel.load(for: song)
        }
    }

    @ViewBuilder
    private var background: some View {
        Color.black
            .overlay {
                if let url = player.currentSong?.coverURL {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image
                                .resizable()
                                .scaledToFill()
                                .blur(radius: 70)
                        }
                    }
                }
            }
            .overlay(Color.black.opacity(0.65))
            .clipped()
            .ignoresSafeArea()
    }

    /// Cover + title + artist on the left, the track's own actions on the
    /// right: favourite it, or open the overflow. Dismiss is the chevron,
    /// kept last so its position matches the full player.
    private var header: some View {
        HStack(spacing: 12) {
            AsyncCoverImage(
                url: player.currentSong?.coverURL,
                cornerRadius: 10,
                displaySize: 48
            )
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(player.currentSong?.title ?? "")
                    .font(LaxifyTypography.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(player.currentSong?.artistName ?? "")
                    .font(LaxifyTypography.footnote)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            FavouriteHeart(isOn: isFavorite) { toggleFavorite() }

            Menu {
                if let shareableLyrics {
                    ShareLink(item: shareableLyrics) {
                        Label(L("player.lyricsShare", "Поделиться текстом"), systemImage: "square.and.arrow.up")
                    }
                }

                Menu {
                    ForEach(LyricsFontStep.allCases) { step in
                        Button {
                            fontScale = step.scale
                        } label: {
                            if abs(fontScale - step.scale) < 0.01 {
                                Label(step.title, systemImage: "checkmark")
                            } else {
                                Text(step.title)
                            }
                        }
                    }
                } label: {
                    Label(L("player.lyricsSize", "Размер текста"), systemImage: "textformat.size")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .disabled(shareableLyrics == nil)

            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, LaxifyMetrics.screenPadding)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading {
            Spacer()
            ProgressView()
                .tint(.white)
            Spacer()
        } else if let lyrics = viewModel.lyrics, lyrics.isSynced {
            syncedList(lyrics)
        } else if let plain = viewModel.lyrics?.plainText, !plain.isEmpty {
            plainScroll(plain)
        } else if viewModel.hasLoaded {
            Spacer()
            Text(L("player.lyricsNotFound", "Текст песни не найден"))
                .font(LaxifyTypography.body)
                .foregroundStyle(.white.opacity(0.6))
            Spacer()
        } else {
            Spacer()
        }
    }

    private func syncedList(_ lyrics: Lyrics) -> some View {
        // Driven by the display rather than by the player's periodic
        // observer: the observer hops to the main actor before a view sees
        // it, which is enough delay for the highlight to trail the vocal.
        TimelineView(.animation) { _ in
            syncedBody(lyrics, at: player.preciseTime)
        }
    }

    private func syncedBody(_ lyrics: Lyrics, at time: TimeInterval) -> some View {
        let activeIndex = viewModel.activeLineIndex(at: time)

        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Color.clear.frame(height: 20)

                    ForEach(Array(lyrics.syncedLines.enumerated()), id: \.element.id) { index, line in
                        lineView(
                            line,
                            isActive: index == activeIndex,
                            isPast: activeIndex.map { index < $0 } ?? false,
                            at: time,
                            wordByWord: !lyrics.isApproximate
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(index)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            player.seek(to: line.timestamp)
                        }
                        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: activeIndex)
                    }

                    Color.clear.frame(height: 220)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, LaxifyMetrics.screenPadding)
            }
            .onChange(of: activeIndex) { _, newValue in
                guard let newValue else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private func lineView(
        _ line: LyricLine,
        isActive: Bool,
        isPast: Bool,
        at time: TimeInterval,
        wordByWord: Bool
    ) -> some View {
        let text = line.text.isEmpty ? "♪" : line.text

        if isActive && wordByWord {
            // Real timestamps from the source: safe to fill word by word.
            let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            let progress = viewModel.lineProgress(at: time)
            let spoken = progress * Double(words.count)

            WordFlowLayout(horizontalSpacing: 7, lineSpacing: 6) {
                ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                    let isSung = Double(index) < spoken
                    Text(word)
                        .font(.system(size: 26 * fontScale, weight: .bold))
                        .foregroundStyle(isSung ? .white : .white.opacity(0.3))
                        .shadow(color: .white.opacity(isSung ? 0.3 : 0), radius: 10)
                        .scaleEffect(isSung ? 1 : 0.95, anchor: .bottom)
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSung)
                }
            }
        } else if isActive {
            // Estimated timings: highlight the whole line and let it breathe.
            // Filling word by word off an estimate looks like the lyrics are
            // simply wrong as soon as it drifts.
            Text(text)
                .font(.system(size: 26 * fontScale, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .white.opacity(0.22), radius: 12)
                .transition(.opacity)
        } else {
            Text(text)
                .font(.system(size: 21 * fontScale, weight: .semibold))
                .foregroundStyle(.white.opacity(isPast ? 0.26 : 0.42))
                .blur(radius: 0.5)
                .scaleEffect(0.94, anchor: .leading)
        }
    }

    private func plainScroll(_ text: String) -> some View {
        ScrollView {
            Text(text)
                .font(.system(size: 16 * fontScale, weight: .regular))
                .foregroundStyle(.white.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, LaxifyMetrics.screenPadding)
                .padding(.bottom, 40)
        }
    }

    // MARK: - Actions

    private func toggleFavorite() {
        guard let song = player.currentSong else { return }
        if let existing = favorites.first(where: { $0.id == song.id }) {
            modelContext.delete(existing)
            SyncService.shared.favoriteRemoved(trackId: song.id)
        } else {
            modelContext.insert(FavoriteTrack(song: song))
            SyncService.shared.favoriteAdded(song)
        }
    }

    /// Title, artist and the words, ready to send. Nil when there is nothing
    /// to share yet, which also disables the overflow button.
    private var shareableLyrics: String? {
        guard let song = player.currentSong else { return nil }

        let body: String?
        if let synced = viewModel.lyrics?.syncedLines, !synced.isEmpty {
            body = synced.map(\.text).joined(separator: "\n")
        } else {
            body = viewModel.lyrics?.plainText
        }

        guard let body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return "\(song.title) — \(song.artistName)\n\n\(body)"
    }
}

private enum LyricsFontStep: String, CaseIterable, Identifiable {
    case small, regular, large, huge

    var id: String { rawValue }

    var scale: Double {
        switch self {
        case .small: 0.85
        case .regular: 1.0
        case .large: 1.2
        case .huge: 1.4
        }
    }

    @MainActor
    var title: String {
        switch self {
        case .small: L("lyrics.sizeSmall", "Мелкий")
        case .regular: L("lyrics.sizeRegular", "Обычный")
        case .large: L("lyrics.sizeLarge", "Крупный")
        case .huge: L("lyrics.sizeHuge", "Очень крупный")
        }
    }
}

#Preview {
    LyricsView()
}
