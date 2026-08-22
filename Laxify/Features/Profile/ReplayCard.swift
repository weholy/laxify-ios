import SwiftUI

/// The way into the story, sitting in the profile.
///
/// Shows enough to be worth tapping — the month, the number, and who was
/// played most — in the colours of that month's artwork, so the card itself
/// changes as listening does rather than staying a static button.
struct ReplayEntryCard: View {
    var onOpen: (ReplaySummary, ReplaySummary?) -> Void

    @State private var summary: ReplaySummary?
    @State private var previous: ReplaySummary?
    @State private var palette: ArtworkPalette = .neutral
    @State private var isLoading = true

    var body: some View {
        Group {
            if let summary, !summary.isEmpty {
                card(summary)
            } else if isLoading {
                placeholder
            }
            // Nothing at all when there is no listening yet: an empty card
            // advertising emptiness is worse than the space it takes.
        }
        .task { await load() }
    }

    private func card(_ summary: ReplaySummary) -> some View {
        Button {
            onOpen(summary, previous)
        } label: {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(summary.period.title.uppercased())
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(palette.secondaryText)
                        .kerning(1.4)

                    Text(summary.totalMinutes.spaced)
                        .font(.system(size: 40, weight: .black))
                        .foregroundStyle(palette.textColor)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)

                    Text("минут музыки")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(palette.textColor.opacity(0.8))

                    if let leader = summary.topArtists.first {
                        Text("Чаще всего — \(leader.name)")
                            .font(.system(size: 12))
                            .foregroundStyle(palette.secondaryText)
                            .lineLimit(1)
                            .padding(.top, 2)
                    }
                }

                Spacer(minLength: 0)

                if let artwork = summary.topArtists.first?.artworkURL
                    ?? summary.topTracks.first?.artworkURL {
                    AsyncCoverImage(url: artwork, cornerRadius: 30, displaySize: 130)
                        .frame(width: 104, height: 104)
                        .shadow(color: .black.opacity(0.28), radius: 16, y: 8)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: LaxifyMetrics.cardCornerRadius, style: .continuous)
                    .fill(palette.gradient)
            }
            .clipShape(
                RoundedRectangle(cornerRadius: LaxifyMetrics.cardCornerRadius, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: LaxifyMetrics.cardCornerRadius, style: .continuous)
            .fill(LaxifyPalette.surface)
            .frame(height: 140)
            .overlay {
                ProgressView().tint(LaxifyPalette.textTertiary)
            }
    }

    private func load() async {
        defer { isLoading = false }

        guard let periods = try? await LaxifyAPI.shared.replayPeriods(),
              let opening = periods.first(where: \.isCurrent) ?? periods.first(where: { $0.id != "all" }) ?? periods.first
        else { return }

        guard let fresh = try? await LaxifyAPI.shared.replay(period: opening.id) else { return }
        summary = fresh

        // The month before, only so the story can say whether listening went
        // up or down. Absent for the very first month, which is fine.
        if let earlier = periods.first(where: { $0.id != opening.id && $0.id != "all" }) {
            previous = try? await LaxifyAPI.shared.replay(period: earlier.id)
        }

        let artwork = fresh.topArtists.first?.artworkURL ?? fresh.topTracks.first?.artworkURL
        let found = await PaletteExtractor.shared.palette(for: artwork)
        withAnimation(.easeInOut(duration: 0.4)) { palette = found }
    }
}

/// What a presented story needs, in one identifiable value so it can drive a
/// sheet directly.
struct ReplayStory: Identifiable {
    let summary: ReplaySummary
    let previous: ReplaySummary?

    var id: String { summary.period.id }
}
