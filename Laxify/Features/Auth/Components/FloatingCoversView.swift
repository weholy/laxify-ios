import SwiftUI

/// The drifting wall of artwork behind the sign-in screen. Two identical
/// columns are stacked and offset by exactly one column height, so when the
/// animation loops the seam lands on identical content and reads as endless.
struct FloatingCoversView: View {
    let songs: [Song]

    private let cardWidth: CGFloat = 150
    private let spacing: CGFloat = 14
    private let columnCount = 2

    @State private var drift: CGFloat = 0

    private var rows: [[Song]] {
        guard !songs.isEmpty else { return [] }
        return stride(from: 0, to: songs.count, by: columnCount).map { start in
            Array(songs[start..<min(start + columnCount, songs.count)])
        }
    }

    private var columnHeight: CGFloat {
        let rowHeight = cardWidth + 52
        return CGFloat(rows.count) * (rowHeight + spacing)
    }

    var body: some View {
        VStack(spacing: spacing) {
            grid
            grid
        }
        .offset(y: drift)
        .onAppear {
            guard columnHeight > 0 else { return }
            drift = 0
            withAnimation(.linear(duration: Double(rows.count) * 2.4).repeatForever(autoreverses: false)) {
                drift = -columnHeight
            }
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
        VStack(alignment: .leading, spacing: 8) {
            AsyncCoverImage(url: song.coverURL, cornerRadius: 20)
                .frame(width: cardWidth, height: cardWidth)

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

/// Shown until real artwork arrives — and if the network never answers, this
/// stays as the backdrop rather than leaving the screen empty.
struct PlaceholderCoversView: View {
    private let cardWidth: CGFloat = 150
    private let spacing: CGFloat = 14

    @State private var drift: CGFloat = 0

    private let palette: [[Color]] = [
        [Color(hex: 0x0A84FF), Color(hex: 0x5E5CE6)],
        [Color(hex: 0xFF375F), Color(hex: 0xFF9F0A)],
        [Color(hex: 0x30D158), Color(hex: 0x0A84FF)],
        [Color(hex: 0xBF5AF2), Color(hex: 0xFF375F)],
        [Color(hex: 0x64D2FF), Color(hex: 0x5E5CE6)],
        [Color(hex: 0xFF9F0A), Color(hex: 0xFF375F)]
    ]

    private var columnHeight: CGFloat {
        CGFloat(palette.count / 2) * (cardWidth + 52 + spacing)
    }

    var body: some View {
        VStack(spacing: spacing) {
            grid
            grid
        }
        .offset(y: drift)
        .onAppear {
            withAnimation(.linear(duration: 14).repeatForever(autoreverses: false)) {
                drift = -columnHeight
            }
        }
        .allowsHitTesting(false)
    }

    private var grid: some View {
        VStack(spacing: spacing) {
            ForEach(0..<(palette.count / 2), id: \.self) { row in
                HStack(spacing: spacing) {
                    ForEach(0..<2, id: \.self) { column in
                        let index = row * 2 + column
                        VStack(alignment: .leading, spacing: 8) {
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

                            VStack(alignment: .leading, spacing: 4) {
                                Capsule()
                                    .fill(LaxifyPalette.textPrimary.opacity(0.25))
                                    .frame(width: cardWidth * 0.7, height: 9)
                                Capsule()
                                    .fill(LaxifyPalette.textPrimary.opacity(0.15))
                                    .frame(width: cardWidth * 0.45, height: 8)
                            }
                        }
                    }
                }
            }
        }
    }
}
