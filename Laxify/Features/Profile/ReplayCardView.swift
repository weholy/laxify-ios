import SwiftUI

/// One card of the story.
///
/// Every card follows the same shape — a quiet line saying what this is, the
/// thing itself as large as it will go, and a line underneath — so swiping
/// through them feels like one piece rather than seven screens.
struct ReplayCardView: View {
    let card: ReplayCard
    let palette: ArtworkPalette

    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)

            content
                .opacity(revealed ? 1 : 0)
                .offset(y: revealed ? 0 : 28)
                .blur(radius: revealed ? 0 : 6)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.vertical, 60)
        .onAppear {
            // Deliberately unhurried: the card is already on screen before it
            // resolves, so the reveal reads as it settling rather than as
            // something arriving late.
            withAnimation(.spring(response: 0.75, dampingFraction: 0.82).delay(0.1)) {
                revealed = true
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch card {
        case .opening(let period, let subtitle):
            opening(period, subtitle)
        case .minutes(let value, let comparison):
            minutes(value, comparison)
        case .topArtist(let artist):
            topArtist(artist)
        case .artistLine(let artists):
            artistLine(artists)
        case .onRepeat(let tracks):
            onRepeat(tracks)
        case .genres(let genres):
            genres_(genres)
        case .habit(let days, let streak, let artists, let tracks):
            habit(days, streak, artists, tracks)
        }
    }

    // MARK: - Cards

    private func opening(_ period: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            eyebrow("Laxify")

            Text(period)
                .font(.system(size: 64, weight: .black))
                .foregroundStyle(palette.textColor)
                .minimumScaleFactor(0.4)
                .lineLimit(2)

            Text(subtitle)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(palette.secondaryText)
        }
    }

    private func minutes(_ value: Int, _ comparison: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            eyebrow("Вы слушали")

            Text(value.spaced)
                .font(.system(size: 92, weight: .black))
                .foregroundStyle(palette.textColor)
                .minimumScaleFactor(0.35)
                .lineLimit(1)

            Text("минут")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(palette.textColor.opacity(0.85))

            if let comparison {
                Text(comparison)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(palette.secondaryText)
                    .padding(.top, 16)
            }
        }
    }

    private func topArtist(_ artist: ReplayArtist) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            eyebrow("Артист месяца")

            AsyncCoverImage(url: artist.artworkURL, cornerRadius: 34, displaySize: 300)
                .frame(width: 250, height: 250)
                .shadow(color: .black.opacity(0.35), radius: 28, y: 14)

            VStack(alignment: .leading, spacing: 4) {
                Text(artist.name)
                    .font(.system(size: 40, weight: .black))
                    .foregroundStyle(palette.textColor)
                    .minimumScaleFactor(0.4)
                    .lineLimit(2)

                Text("\(artist.minutes.spaced) минут · \(artist.plays) прослушиваний")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(palette.secondaryText)
            }
        }
    }

    private func artistLine(_ artists: [ReplayArtist]) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            eyebrow("Ваша пятёрка")

            VStack(spacing: 14) {
                ForEach(Array(artists.enumerated()), id: \.element.id) { index, artist in
                    HStack(spacing: 14) {
                        Text("\(index + 1)")
                            .font(.system(size: 30, weight: .black))
                            .foregroundStyle(palette.textColor.opacity(index == 0 ? 1 : 0.4))
                            .frame(width: 40, alignment: .leading)

                        AsyncCoverImage(url: artist.artworkURL, cornerRadius: 26, displaySize: 60)
                            .frame(width: 52, height: 52)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(artist.name)
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(palette.textColor)
                                .lineLimit(1)

                            Text("\(artist.minutes.spaced) мин")
                                .font(.system(size: 13))
                                .foregroundStyle(palette.secondaryText)
                        }

                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func onRepeat(_ tracks: [ReplayTrack]) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            eyebrow("На повторе")

            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                HStack(spacing: 14) {
                    AsyncCoverImage(url: track.artworkURL, cornerRadius: 18, displaySize: 80)
                        .frame(width: 64, height: 64)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(palette.textColor)
                            .lineLimit(2)

                        Text(track.artistName)
                            .font(.system(size: 14))
                            .foregroundStyle(palette.secondaryText)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    Text("\(track.plays)")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(palette.textColor)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(palette.textColor.opacity(0.14), in: Capsule())
                }
                .opacity(index == 0 ? 1 : 0.82)
            }
        }
    }

    private func genres_(_ genres: [ReplayGenre]) -> some View {
        let total = max(genres.map(\.plays).reduce(0, +), 1)

        return VStack(alignment: .leading, spacing: 20) {
            eyebrow("Ваши жанры")

            // Sized by share, so the shape of a taste is visible without
            // reading a single number.
            FlowLayout(spacing: 10) {
                ForEach(genres) { genre in
                    let share = Double(genre.plays) / Double(total)

                    Text(genre.name)
                        .font(.system(size: 18 + share * 22, weight: .black))
                        .foregroundStyle(palette.textColor.opacity(0.55 + share * 0.45))
                }
            }

            if let leader = genres.first {
                Text("Чаще всего — \(leader.name.lowercased())")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(palette.secondaryText)
                    .padding(.top, 8)
            }
        }
    }

    private func habit(_ days: Int, _ streak: Int, _ artists: Int, _ tracks: Int) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            eyebrow("И ещё")

            VStack(alignment: .leading, spacing: 18) {
                statLine(days, "дней с музыкой")
                statLine(streak, "дней подряд")
                statLine(artists, "разных артистов")
                statLine(tracks, "разных треков")
            }
        }
    }

    private func statLine(_ value: Int, _ caption: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(value.spaced)
                .font(.system(size: 46, weight: .black))
                .foregroundStyle(palette.textColor)
                .frame(minWidth: 90, alignment: .leading)

            Text(caption)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(palette.secondaryText)
        }
    }

    private func eyebrow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .heavy))
            .foregroundStyle(palette.secondaryText)
            .textCase(.uppercase)
            .kerning(1.6)
            .padding(.bottom, 6)
    }
}

extension Int {
    /// Grouped with thin spaces, which is how large numbers are written in
    /// Russian — 9 218 rather than 9,218.
    var spaced: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = "\u{2009}"
        return formatter.string(from: NSNumber(value: self)) ?? "\(self)"
    }
}
