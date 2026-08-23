import SwiftUI

/// The way into the story, sitting in the profile.
///
/// Shows enough to be worth tapping — the month, the number, and who was
/// played most — in the colours of that month's artwork, so the card itself
/// changes as listening does rather than staying a static button.
struct ReplayEntryCard: View {
    var onOpen: (ReplaySummary, ReplaySummary?) -> Void

    @Environment(\.modelContext) private var modelContext

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
        .onReceive(NotificationCenter.default.publisher(for: .laxifyPlayRecorded)) { _ in
            let local = LocalReplay.bundle(context: modelContext)
            guard let fresh = local.current else { return }
            withAnimation(.easeOut(duration: 0.4)) {
                summary = fresh
                previous = local.previous
            }
        }
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

        // Whatever this device recorded, straight away. Waiting on the server
        // is what made the card appear and disappear.
        let local = LocalReplay.bundle(context: modelContext)
        if let fresh = local.current {
            summary = fresh
            previous = local.previous
            await applyPalette(for: fresh)
        }

        guard let bundle = try? await LaxifyAPI.shared.replayBundle(),
              let fresh = bundle.current
        else { return }

        summary = fresh
        previous = bundle.previous

        await applyPalette(for: fresh)
    }

    private func applyPalette(for summary: ReplaySummary) async {
        let artwork = summary.topArtists.first?.artworkURL ?? summary.topTracks.first?.artworkURL
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
