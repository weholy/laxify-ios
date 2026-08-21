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
        ZStack {
            Color.black

            if let url = player.currentSong?.coverURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .scaledToFill()
                    }
                }
                .blur(radius: 70)
            }

            Color.black.opacity(0.65)
        }
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
        let activeIndex = viewModel.activeLineIndex(at: player.currentTime)

        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Color.clear.frame(height: 20)

                    ForEach(Array(lyrics.syncedLines.enumerated()), id: \.element.id) { index, line in
                        Text(line.text.isEmpty ? "···" : line.text)
                            .font(index == activeIndex ? LaxifyTypography.title : LaxifyTypography.body)
                            .fontWeight(index == activeIndex ? .bold : .regular)
                            .foregroundStyle(index == activeIndex ? .white : .white.opacity(0.4))
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                player.seek(to: line.timestamp)
                            }
                            .animation(.easeInOut(duration: 0.25), value: activeIndex)
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
