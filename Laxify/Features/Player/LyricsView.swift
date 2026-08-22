import SwiftUI

struct LyricsView: View {
    @Environment(\.dismiss) private var dismiss
    var player = AudioPlayerController.shared
    @State private var viewModel = LyricsViewModel()

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

    private var header: some View {
        HStack {
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

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
            }
            .laxGlassCircle(interactive: true)
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
            Text("Текст песни не найден")
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
                            at: time
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
        _ line: LyricLine, isActive: Bool, isPast: Bool, at time: TimeInterval
    ) -> some View {
        let text = line.text.isEmpty ? "♪" : line.text

        if isActive {
            let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            let progress = viewModel.lineProgress(at: time)
            let spoken = progress * Double(words.count)

            WordFlowLayout(horizontalSpacing: 7, lineSpacing: 6) {
                ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                    let isSung = Double(index) < spoken
                    Text(word)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(isSung ? .white : .white.opacity(0.3))
                        .shadow(color: .white.opacity(isSung ? 0.3 : 0), radius: 10)
                        .scaleEffect(isSung ? 1 : 0.95, anchor: .bottom)
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSung)
                }
            }
        } else {
            Text(text)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(.white.opacity(isPast ? 0.26 : 0.42))
                .blur(radius: 0.5)
                .scaleEffect(0.94, anchor: .leading)
        }
    }

    private func plainScroll(_ text: String) -> some View {
        ScrollView {
            Text(text)
                .font(LaxifyTypography.body)
                .foregroundStyle(.white.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, LaxifyMetrics.screenPadding)
                .padding(.bottom, 40)
        }
    }
}

#Preview {
    LyricsView()
}
