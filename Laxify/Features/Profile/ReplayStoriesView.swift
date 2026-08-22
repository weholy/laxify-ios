import SwiftUI

/// A month of listening, told one screen at a time.
///
/// Numbers in a table are read once and forgotten. The same numbers set very
/// large, one to a screen, over colour taken from the artwork behind them,
/// are worth swiping through — which is the only reason anyone comes back to
/// look at their own statistics.
///
/// Swiped rather than timed: nobody should be hurried past the one card they
/// actually wanted to look at.
struct ReplayStoriesView: View {
    let summary: ReplaySummary
    let previous: ReplaySummary?
    var onClose: () -> Void

    @State private var palette: ArtworkPalette = .neutral
    @State private var current = 0

    private var cards: [ReplayCard] {
        ReplayCard.build(from: summary, previous: previous)
    }

    var body: some View {
        ZStack {
            palette.gradient.ignoresSafeArea()

            // A soft light from the top edge, so a flat gradient reads as lit
            // rather than printed.
            RadialGradient(
                colors: [palette.accent.opacity(0.45), .clear],
                center: .top,
                startRadius: 10,
                endRadius: 520
            )
            .ignoresSafeArea()
            .blendMode(.plusLighter)

            TabView(selection: $current) {
                ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                    ReplayCardView(card: card, palette: palette)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .rotationEffect(.degrees(-90))
            .frame(width: UIScreen.main.bounds.height, height: UIScreen.main.bounds.width)
            .rotationEffect(.degrees(90), anchor: .topLeading)
            .offset(x: UIScreen.main.bounds.width)
            .ignoresSafeArea()

            progress
            closeButton
        }
        .task {
            let artwork = summary.topArtists.first?.artworkURL ?? summary.topTracks.first?.artworkURL
            let found = await PaletteExtractor.shared.palette(for: artwork)
            withAnimation(.easeInOut(duration: 0.6)) { palette = found }
        }
    }

    /// Ticks across the top, one per card — the shape people already read as
    /// "there are this many, you are here".
    private var progress: some View {
        VStack {
            HStack(spacing: 4) {
                ForEach(cards.indices, id: \.self) { index in
                    Capsule()
                        .fill(palette.textColor.opacity(index <= current ? 0.9 : 0.28))
                        .frame(height: 3)
                }
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)
            .padding(.top, 8)
            .animation(.easeOut(duration: 0.25), value: current)

            Spacer()
        }
    }

    private var closeButton: some View {
        VStack {
            HStack {
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(palette.textColor)
                        .frame(width: 34, height: 34)
                        .background(palette.textColor.opacity(0.14), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)
            .padding(.top, 22)

            Spacer()
        }
    }
}

// MARK: - What the cards are

/// One screen of the story.
enum ReplayCard: Identifiable {
    case opening(period: String, subtitle: String)
    case minutes(Int, comparison: String?)
    case topArtist(ReplayArtist)
    case artistLine([ReplayArtist])
    case onRepeat([ReplayTrack])
    case genres([ReplayGenre])
    case habit(activeDays: Int, streak: Int, artists: Int, tracks: Int)

    var id: String {
        switch self {
        case .opening: "opening"
        case .minutes: "minutes"
        case .topArtist: "top-artist"
        case .artistLine: "artists"
        case .onRepeat: "repeat"
        case .genres: "genres"
        case .habit: "habit"
        }
    }

    /// Builds the run, skipping anything there is nothing to say about.
    ///
    /// A card reading "0 artists" is worse than no card: it draws attention
    /// to the gap rather than to the listening.
    static func build(from summary: ReplaySummary, previous: ReplaySummary?) -> [ReplayCard] {
        var cards: [ReplayCard] = [
            .opening(
                period: summary.period.title,
                subtitle: summary.period.id == "all" ? "Всё, что вы слушали" : "Ваш месяц в музыке"
            ),
            .minutes(summary.totalMinutes, comparison: comparison(summary, previous)),
        ]

        if let leader = summary.topArtists.first {
            cards.append(.topArtist(leader))
        }

        if summary.topArtists.count > 1 {
            cards.append(.artistLine(Array(summary.topArtists.prefix(5))))
        }

        if !summary.topTracks.isEmpty {
            cards.append(.onRepeat(Array(summary.topTracks.prefix(4))))
        }

        if !summary.genres.isEmpty {
            cards.append(.genres(summary.genres))
        }

        cards.append(
            .habit(
                activeDays: summary.activeDays,
                streak: summary.longestStreakDays,
                artists: summary.distinctArtists,
                tracks: summary.distinctTracks
            )
        )

        return cards
    }

    /// How this month compares with the one before it, in words.
    private static func comparison(_ summary: ReplaySummary, _ previous: ReplaySummary?) -> String? {
        guard let previous, previous.totalMinutes > 0, summary.period.id != "all" else {
            return nil
        }

        let change = Double(summary.totalMinutes - previous.totalMinutes) / Double(previous.totalMinutes)
        let percent = Int((abs(change) * 100).rounded())

        // Below this it is noise, and saying "on par" is more honest than
        // reporting a three percent swing as a trend.
        guard percent >= 8 else { return "Примерно как в прошлом месяце" }

        return change > 0
            ? "На \(percent)% больше, чем в прошлом месяце"
            : "На \(percent)% меньше, чем в прошлом месяце"
    }
}
