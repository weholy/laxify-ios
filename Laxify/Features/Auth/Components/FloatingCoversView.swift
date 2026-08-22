import SwiftUI

/// The drifting wall of artwork behind the sign-in screen.
///
/// Driven by `TimelineView` rather than a repeating animation on purpose: the
/// artwork arrives asynchronously, and a `repeatForever` animation started in
/// `onAppear` would have been kicked off while the list was still empty (so
/// with nothing to travel) and never restart once covers loaded. Deriving the
/// offset from the clock instead means it is always correct for whatever is
/// on screen at that moment.
struct FloatingCoversView: View {
    let songs: [Song]

    private let cardWidth: CGFloat = 148
    private let spacing: CGFloat = 14
    private let columns = 2
    private let pointsPerSecond: CGFloat = 22

    private var rows: [[Song]] {
        guard !songs.isEmpty else { return [] }
        return stride(from: 0, to: songs.count, by: columns).map { start in
            Array(songs[start..<min(start + columns, songs.count)])
        }
    }

    private var rowHeight: CGFloat { cardWidth + 46 }
    private var columnHeight: CGFloat { CGFloat(rows.count) * (rowHeight + spacing) }

    var body: some View {
        TimelineView(.animation) { timeline in
            let elapsed = timeline.date.timeIntervalSinceReferenceDate
            let travelled = columnHeight > 0
                ? CGFloat(elapsed) * pointsPerSecond
                : 0
            // Wrapping on one column height lands the seam on identical
            // content, so the loop is invisible.
            let offset = columnHeight > 0
                ? -travelled.truncatingRemainder(dividingBy: columnHeight)
                : 0

            VStack(spacing: spacing) {
                grid
                grid
            }
            .offset(y: offset)
        }
        .allowsHitTesting(false)
    }

    private var grid: some View {
        VStack(spacing: spacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: spacing) {
                    ForEach(row) { song in
                        card(song)
                    }
                }
            }
        }
    }

    private func card(_ song: Song) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            AsyncCoverImage(url: song.coverURL, cornerRadius: 20)
                .frame(width: cardWidth, height: cardWidth)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 5)

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LaxifyPalette.textPrimary)
                    .lineLimit(1)
                Text(song.artistName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(LaxifyPalette.textSecondary)
                    .lineLimit(1)
            }
            .frame(width: cardWidth, alignment: .leading)
        }
    }
}

/// Shown until real artwork arrives, and kept as the backdrop if the network
/// never answers, so the screen is never blank.
struct PlaceholderCoversView: View {
    private let cardWidth: CGFloat = 148
    private let spacing: CGFloat = 14
    private let pointsPerSecond: CGFloat = 22

    private let palette: [[Color]] = [
        [Color(hex: 0x0A84FF), Color(hex: 0x5E5CE6)],
        [Color(hex: 0xFF375F), Color(hex: 0xFF9F0A)],
        [Color(hex: 0x30D158), Color(hex: 0x0A84FF)],
        [Color(hex: 0xBF5AF2), Color(hex: 0xFF375F)],
        [Color(hex: 0x64D2FF), Color(hex: 0x5E5CE6)],
        [Color(hex: 0xFF9F0A), Color(hex: 0xFF375F)]
    ]

    private var rowHeight: CGFloat { cardWidth + 46 }
    private var columnHeight: CGFloat { CGFloat(palette.count / 2) * (rowHeight + spacing) }

    var body: some View {
        TimelineView(.animation) { timeline in
            let elapsed = timeline.date.timeIntervalSinceReferenceDate
            let offset = -(CGFloat(elapsed) * pointsPerSecond)
                .truncatingRemainder(dividingBy: columnHeight)

            VStack(spacing: spacing) {
                grid
                grid
            }
            .offset(y: offset)
        }
        .allowsHitTesting(false)
    }

    private var grid: some View {
        VStack(spacing: spacing) {
            ForEach(0..<(palette.count / 2), id: \.self) { row in
                HStack(spacing: spacing) {
                    ForEach(0..<2, id: \.self) { column in
                        card(index: row * 2 + column)
                    }
                }
            }
        }
    }

    private func card(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: palette[index % palette.count],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: cardWidth, height: cardWidth)
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .shadow(color: .black.opacity(0.18), radius: 10, y: 5)

            VStack(alignment: .leading, spacing: 5) {
                Capsule()
                    .fill(LaxifyPalette.textPrimary.opacity(0.22))
                    .frame(width: cardWidth * 0.7, height: 9)
                Capsule()
                    .fill(LaxifyPalette.textPrimary.opacity(0.13))
                    .frame(width: cardWidth * 0.45, height: 8)
            }
        }
    }
}
