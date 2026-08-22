import SwiftUI

/// What a month of listening looked like.
///
/// Built to be looked at rather than read: a few very large numbers, the
/// artwork of what was played most, and a wash of colour drawn from that
/// artwork behind it all. The figures come from the play log on the server,
/// so they are the same on every device and survive a reinstall.
struct ReplayView: View {
    var onClose: () -> Void

    @State private var periods: [ReplayPeriod] = []
    @State private var selected: ReplayPeriod?
    @State private var summary: ReplaySummary?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var appear = false
    @State private var palette: ArtworkPalette = .neutral

    var body: some View {
        ZStack {
            LaxifyPalette.background.ignoresSafeArea()
            backdrop

            VStack(spacing: 0) {
                header

                if !periods.isEmpty {
                    periodStrip
                }

                content
            }
            .opacity(appear ? 1 : 0)
        }
        .task { await load() }
        .onAppear {
            withAnimation(.easeOut(duration: 0.4)) { appear = true }
        }
    }

    // MARK: - Chrome

    /// Colour taken from what was played most, so each month looks like its
    /// own music rather than like a template.
    ///
    /// Read from the artwork rather than blurred behind the content: a blur
    /// of a square image leaves the bottom of a tall screen empty, and the
    /// colours it does produce are muddier than the ones the image is
    /// actually made of.
    private var backdrop: some View {
        ZStack {
            palette.gradient

            // A soft light from the top edge, so a flat gradient reads as lit
            // rather than printed.
            RadialGradient(
                colors: [palette.accent.opacity(0.4), .clear],
                center: .top,
                startRadius: 10,
                endRadius: 480
            )
            .blendMode(.plusLighter)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: summary?.period.id)
    }

    private var header: some View {
        HStack {
            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.textColor)
                    .frame(width: 38, height: 38)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)

            Spacer()

            Text("Статистика")
                .font(LaxifyTypography.headline)
                .foregroundStyle(palette.textColor)

            Spacer()

            Color.clear.frame(width: 38, height: 38)
        }
        .padding(.horizontal, LaxifyMetrics.screenPadding)
        .padding(.bottom, 8)
    }

    /// Months across the top. The selected one is the only bright thing, the
    /// rest recede — the same idea as flicking through a year.
    private var periodStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    ForEach(periods) { period in
                        Button {
                            select(period)
                        } label: {
                            Text(period.shortTitle)
                                .font(.system(
                                    size: 17,
                                    weight: period.id == selected?.id ? .bold : .medium
                                ))
                                .foregroundStyle(
                                    period.id == selected?.id
                                        ? palette.textColor
                                        : palette.textColor.opacity(0.45)
                                )
                        }
                        .buttonStyle(.plain)
                        .id(period.id)
                    }
                }
                .padding(.horizontal, LaxifyMetrics.screenPadding)
                .padding(.vertical, 10)
            }
            .onChange(of: selected?.id) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    // MARK: - Body

    @ViewBuilder
    private var content: some View {
        if isLoading && summary == nil {
            Spacer()
            ProgressView().tint(palette.secondaryText)
            Spacer()
        } else if let errorMessage {
            Spacer()
            Text(errorMessage)
                .font(LaxifyTypography.body)
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        } else if let summary, summary.isEmpty {
            emptyState
        } else if let summary {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    headline(summary)
                    figures(summary)

                    if !summary.topArtists.isEmpty {
                        artistsSection(summary.topArtists)
                    }

                    if !summary.topTracks.isEmpty {
                        tracksSection(summary.topTracks)
                    }

                    if !summary.genres.isEmpty {
                        genresSection(summary.genres)
                    }

                    habitSection(summary)
                }
                .padding(.bottom, 130)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 38))
                .foregroundStyle(palette.textColor.opacity(0.45))
            Text("Здесь пока пусто")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(palette.textColor)
            Text("Послушайте что-нибудь — и здесь появится\nваша статистика за этот период")
                .font(LaxifyTypography.footnote)
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)
            Spacer()
        }
    }

    /// The one sentence worth leading with, set very large.
    private func headline(_ summary: ReplaySummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(summary.period.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.secondaryText)
                .textCase(.uppercase)
                .kerning(1.2)

            Text("\(summary.totalMinutes.spaced)")
                .font(.system(size: 72, weight: .heavy, design: .default))
                .foregroundStyle(palette.textColor)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .contentTransition(.numericText())

            Text("минут прослушано")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(palette.secondaryText)
        }
        .padding(.horizontal, LaxifyMetrics.screenPadding)
        .padding(.top, 12)
    }

    private func figures(_ summary: ReplaySummary) -> some View {
        HStack(spacing: 10) {
            figure(summary.totalPlays, "прослушиваний")
            figure(summary.distinctArtists, "артистов")
            figure(summary.distinctTracks, "треков")
        }
        .padding(.horizontal, LaxifyMetrics.screenPadding)
    }

    private func figure(_ value: Int, _ caption: String) -> some View {
        VStack(spacing: 4) {
            Text(value.spaced)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(palette.textColor)
                .minimumScaleFactor(0.6)
                .lineLimit(1)

            Text(caption)
                .font(.system(size: 12))
                .foregroundStyle(palette.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .glassEffect(.regular, in: .rect(cornerRadius: 32))
    }

    private func artistsSection(_ artists: [ReplayArtist]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Ваши артисты")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(Array(artists.enumerated()), id: \.element.id) { index, artist in
                        artistCard(artist, rank: index + 1)
                    }
                }
                .padding(.horizontal, LaxifyMetrics.screenPadding)
            }
        }
    }

    private func artistCard(_ artist: ReplayArtist, rank: Int) -> some View {
        ZStack(alignment: .bottomLeading) {
            AsyncCoverImage(url: artist.artworkURL, cornerRadius: 38, displaySize: 180)
                .frame(width: 168, height: 210)

            // A gradient rather than a flat scrim: the name has to stay
            // legible over artwork that could be any colour at all.
            LinearGradient(
                colors: [.clear, .black.opacity(0.15), .black.opacity(0.75)],
                startPoint: .center,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(artist.name)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text("\(artist.minutes.spaced) мин")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .padding(14)

            Text("\(rank)")
                .font(.system(size: 40, weight: .heavy))
                .foregroundStyle(.white.opacity(0.9))
                .shadow(color: .black.opacity(0.4), radius: 8)
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 168, height: 210)
        .clipShape(RoundedRectangle(cornerRadius: 38, style: .continuous))
    }

    private func tracksSection(_ tracks: [ReplayTrack]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Чаще всего играло")

            VStack(spacing: 10) {
                ForEach(Array(tracks.prefix(5).enumerated()), id: \.element.id) { index, track in
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(palette.textColor.opacity(0.45))
                            .frame(width: 22)

                        AsyncCoverImage(url: track.artworkURL, cornerRadius: 16, displaySize: 52)
                            .frame(width: 46, height: 46)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(palette.textColor)
                                .lineLimit(1)

                            Text(track.artistName)
                                .font(LaxifyTypography.footnote)
                                .foregroundStyle(palette.secondaryText)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 6)

                        Text("\(track.plays)")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(palette.textColor)
                            + Text(" раз")
                            .font(.system(size: 13))
                            .foregroundStyle(palette.secondaryText)
                    }
                    .padding(12)
                    .glassEffect(.regular, in: .rect(cornerRadius: 30))
                }
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)
        }
    }

    private func genresSection(_ genres: [ReplayGenre]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Что вы слушали")

            // Sized by share rather than listed evenly, so the shape of a
            // taste is visible at a glance.
            let total = max(genres.map(\.plays).reduce(0, +), 1)

            FlowLayout(spacing: 8) {
                ForEach(genres) { genre in
                    let share = Double(genre.plays) / Double(total)

                    Text(genre.name)
                        .font(.system(size: 13 + share * 9, weight: .semibold))
                        .foregroundStyle(palette.textColor)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .glassEffect(.regular, in: .capsule)
                }
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)
        }
    }

    private func habitSection(_ summary: ReplaySummary) -> some View {
        HStack(spacing: 10) {
            figure(summary.activeDays, "дней с музыкой")
            figure(summary.longestStreakDays, "дней подряд")
        }
        .padding(.horizontal, LaxifyMetrics.screenPadding)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(palette.textColor)
            .padding(.horizontal, LaxifyMetrics.screenPadding)
    }

    // MARK: - Loading

    private func load() async {
        isLoading = true
        errorMessage = nil

        do {
            let available = try await LaxifyAPI.shared.replayPeriods()
            periods = available

            // Open on the current month when there is one; otherwise on
            // whatever is most recent.
            let opening = available.first(where: \.isCurrent) ?? available.first
            selected = opening

            if let opening {
                let fresh = try await LaxifyAPI.shared.replay(period: opening.id)
                summary = fresh
                await refreshPalette(for: fresh)
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "Не удалось загрузить статистику"
        }

        isLoading = false
    }

    private func select(_ period: ReplayPeriod) {
        guard period.id != selected?.id else { return }

        withAnimation(.snappy(duration: 0.3)) { selected = period }

        Task {
            guard let fresh = try? await LaxifyAPI.shared.replay(period: period.id) else { return }
            withAnimation(.easeInOut(duration: 0.35)) { summary = fresh }
            await refreshPalette(for: fresh)
        }
    }

    private func refreshPalette(for summary: ReplaySummary) async {
        let artwork = summary.topArtists.first?.artworkURL ?? summary.topTracks.first?.artworkURL
        let found = await PaletteExtractor.shared.palette(for: artwork)
        withAnimation(.easeInOut(duration: 0.6)) { palette = found }
    }
}

