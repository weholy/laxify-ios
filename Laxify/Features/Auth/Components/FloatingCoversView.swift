import SwiftUI

/// The drifting wall of artwork behind the sign-in screen.
///
/// Four columns: the two centre ones are full-strength and scroll in opposite
/// directions, while the outer pair is dimmed and clipped by the screen edge
/// to suggest the wall continues past it. Opposing directions keep the motion
/// from reading as one flat sheet sliding by.
///
/// Driven by `TimelineView` rather than a repeating animation on purpose: the
/// artwork arrives asynchronously, and a `repeatForever` started in `onAppear`
/// would have run while the list was empty — with nothing to travel — and
/// never restarted once covers loaded.
struct FloatingCoversView: View {
    let songs: [Song]

    private let centreCardWidth: CGFloat = 140
    private let sideCardWidth: CGFloat = 112
    private let spacing: CGFloat = 12
    private let pointsPerSecond: CGFloat = 20

    var body: some View {
        HStack(alignment: .top, spacing: spacing) {
            column(offsetBy: 0, width: sideCardWidth, up: false, dimmed: true)
            column(offsetBy: 1, width: centreCardWidth, up: true, dimmed: false)
            column(offsetBy: 2, width: centreCardWidth, up: false, dimmed: false)
            column(offsetBy: 3, width: sideCardWidth, up: true, dimmed: true)
        }
        .allowsHitTesting(false)
    }

    /// Each column takes a different slice of the track list, so neighbouring
    /// columns never show the same cover side by side.
    private func slice(_ index: Int) -> [Song] {
        guard !songs.isEmpty else { return [] }
        let rotated = Array(songs[(index * 3 % songs.count)...] + songs[..<(index * 3 % songs.count)])
        return rotated
    }

    private func column(offsetBy index: Int, width: CGFloat, up: Bool, dimmed: Bool) -> some View {
        let items = slice(index)
        let cardHeight = width + 40
        let columnHeight = CGFloat(items.count) * (cardHeight + spacing)

        return TimelineView(.animation) { timeline in
            let elapsed = CGFloat(timeline.date.timeIntervalSinceReferenceDate)
            let travelled = columnHeight > 0
                ? (elapsed * pointsPerSecond).truncatingRemainder(dividingBy: columnHeight)
                : 0
            // Wrapping on one column height puts the seam on identical
            // content, so the loop is invisible either way it runs.
            let offset = up ? -travelled : travelled - columnHeight

            VStack(spacing: spacing) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, song in
                    card(song, width: width)
                }
                ForEach(Array(items.enumerated()), id: \.offset) { _, song in
                    card(song, width: width)
                }
            }
            .offset(y: offset)
        }
        .frame(width: width)
        .opacity(dimmed ? 0.32 : 1)
        .blur(radius: dimmed ? 1.5 : 0)
    }

    private func card(_ song: Song, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncCoverImage(url: song.coverURL, cornerRadius: 18, displaySize: 110)
                .frame(width: width, height: width)
                .shadow(color: .black.opacity(0.2), radius: 8, y: 4)

            Text(song.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LaxifyPalette.textPrimary.opacity(0.75))
                .lineLimit(1)
                .frame(width: width, alignment: .leading)
        }
    }
}

/// Shown only if artwork has never been cached — normally the cached covers
/// render immediately instead, so this is a first-run fallback rather than a
/// loading state every launch.
struct PlaceholderCoversView: View {
    private let centreCardWidth: CGFloat = 140
    private let sideCardWidth: CGFloat = 112
    private let spacing: CGFloat = 12
    private let pointsPerSecond: CGFloat = 20

    private let palette: [[Color]] = [
        [Color(hex: 0x0A84FF), Color(hex: 0x5E5CE6)],
        [Color(hex: 0xFF375F), Color(hex: 0xFF9F0A)],
        [Color(hex: 0x30D158), Color(hex: 0x0A84FF)],
        [Color(hex: 0xBF5AF2), Color(hex: 0xFF375F)],
        [Color(hex: 0x64D2FF), Color(hex: 0x5E5CE6)],
        [Color(hex: 0xFF9F0A), Color(hex: 0xFF375F)]
    ]

    var body: some View {
        HStack(alignment: .top, spacing: spacing) {
            column(seed: 0, width: sideCardWidth, up: false, dimmed: true)
            column(seed: 2, width: centreCardWidth, up: true, dimmed: false)
            column(seed: 4, width: centreCardWidth, up: false, dimmed: false)
            column(seed: 1, width: sideCardWidth, up: true, dimmed: true)
        }
        .allowsHitTesting(false)
    }

    private func column(seed: Int, width: CGFloat, up: Bool, dimmed: Bool) -> some View {
        let count = 5
        let cardHeight = width + 40
        let columnHeight = CGFloat(count) * (cardHeight + spacing)

        return TimelineView(.animation) { timeline in
            let elapsed = CGFloat(timeline.date.timeIntervalSinceReferenceDate)
            let travelled = (elapsed * pointsPerSecond).truncatingRemainder(dividingBy: columnHeight)
            let offset = up ? -travelled : travelled - columnHeight

            VStack(spacing: spacing) {
                ForEach(0..<(count * 2), id: \.self) { index in
                    card(index: seed + index, width: width)
                }
            }
            .offset(y: offset)
        }
        .frame(width: width)
        .opacity(dimmed ? 0.32 : 1)
        .blur(radius: dimmed ? 1.5 : 0)
    }

    private func card(index: Int, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: palette[index % palette.count],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: width, height: width)
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }

            Capsule()
                .fill(LaxifyPalette.textPrimary.opacity(0.2))
                .frame(width: width * 0.65, height: 8)
        }
    }
}
