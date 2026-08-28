import SwiftUI

/// What a stretch of listening looked like — now with tabs, so the ranked
/// lists of artists and tracks get room of their own rather than a peek.
struct ReplayView: View {
    var onClose: () -> Void

    @Environment(\.modelContext) private var modelContext

    enum Tab: String, CaseIterable, Identifiable {
        case overview, artists, tracks, genres
        var id: String { rawValue }
        var titleKey: String {
            switch self {
            case .overview: "stats.overview"
            case .artists: "stats.artists"
            case .tracks: "stats.tracks"
            case .genres: "stats.whatYouHeard"
            }
        }
        var fallback: String {
            switch self {
            case .overview: "Обзор"
            case .artists: "Артисты"
            case .tracks: "Треки"
            case .genres: "Жанры"
            }
        }
    }

    @State private var periods: [ReplayPeriod] = []
    @State private var selected: ReplayPeriod?
    @State private var summary: ReplaySummary?
    @State private var tab: Tab = .overview
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var appear = false
    @State private var palette: ArtworkPalette = .neutral
    @Namespace private var tabNamespace

    var body: some View {
        ZStack {
            LaxifyPalette.background.ignoresSafeArea()
            backdrop

            VStack(spacing: 0) {
                header

                if !periods.isEmpty {
                    periodStrip
                }

                if summary?.isEmpty == false {
                    tabBar
                }

                content
            }
            .opacity(appear ? 1 : 0)
            .scaleEffect(appear ? 1 : 0.97)
        }
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .laxifyPlayRecorded)) { _ in
            guard let period = selected else { return }
            let fresh = LocalReplay.summary(period: period, context: modelContext)
            withAnimation(.easeOut(duration: 0.4)) { summary = fresh }
        }
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) { appear = true }
        }
    }

    // MARK: - Chrome

    private var backdrop: some View {
        ZStack {
            palette.gradient
            RadialGradient(
                colors: [palette.accent.opacity(0.4), .clear],
                center: .top, startRadius: 10, endRadius: 480
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
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(palette.textColor)
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)

            Spacer()

            Text(L("stats.title", "Статистика"))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(palette.textColor)

            Spacer()

            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, LaxifyMetrics.screenPadding)
        .padding(.bottom, 8)
    }

    private var periodStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    ForEach(periods) { period in
                        Button {
                            select(period)
                        } label: {
                            Text(period.shortTitle)
                                .font(.system(size: 16, weight: period.id == selected?.id ? .bold : .medium))
                                .foregroundStyle(period.id == selected?.id
                                    ? palette.textColor
                                    : palette.textColor.opacity(0.45))
                        }
                        .buttonStyle(.plain)
                        .id(period.id)
                    }
                }
                .padding(.horizontal, LaxifyMetrics.screenPadding)
                .padding(.vertical, 8)
            }
            .onChange(of: selected?.id) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(Tab.allCases) { option in
                let isOn = tab == option
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { tab = option }
                } label: {
                    Text(L(option.titleKey, option.fallback))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isOn ? palette.textColor : palette.textColor.opacity(0.5))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background {
                            if isOn {
                                Capsule().fill(.white.opacity(0.18))
                                    .matchedGeometryEffect(id: "statsTab", in: tabNamespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(.white.opacity(0.06), in: Capsule())
        .padding(.horizontal, LaxifyMetrics.screenPadding)
        .padding(.bottom, 6)
    }

    // MARK: - Body

    @ViewBuilder
    private var content: some View {
        if isLoading && summary == nil {
            Spacer(); ProgressView().tint(palette.secondaryText); Spacer()
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
                VStack(alignment: .leading, spacing: 26) {
                    switch tab {
                    case .overview: overview(summary)
                    case .artists: rankedArtists(summary.topArtists)
                    case .tracks: rankedTracks(summary.topTracks)
                    case .genres: genreCloud(summary.genres)
                    }
                }
                .padding(.horizontal, LaxifyMetrics.screenPadding)
                .padding(.top, 8)
                .padding(.bottom, 130)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func overview(_ summary: ReplaySummary) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(summary.totalMinutes.spaced)")
                    .font(.system(size: 68, weight: .heavy))
                    .foregroundStyle(palette.textColor)
                    .minimumScaleFactor(0.5).lineLimit(1)
                    .contentTransition(.numericText())
                Text(L("stats.minutes", "минут прослушано"))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(palette.secondaryText)
            }

            HStack(spacing: 10) {
                figure(summary.totalPlays, L("stats.plays", "прослушиваний"))
                figure(summary.distinctArtists, L("stats.artistsCount", "артистов"))
                figure(summary.distinctTracks, L("stats.tracksCount", "треков"))
            }

            if !summary.topArtists.isEmpty {
                sectionTitle(L("stats.yourArtists", "Ваши артисты"))
                ForEach(Array(summary.topArtists.prefix(3).enumerated()), id: \.element.id) { index, artist in
                    artistRow(artist, rank: index + 1)
                }
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { tab = .artists }
                } label: {
                    Text("\(L("common.more", "Ещё")) →")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(palette.textColor)
                }
                .buttonStyle(.plain)
            }

            sectionTitle(L("stats.habit", "Привычка"))
            HStack(spacing: 10) {
                figure(summary.activeDays, L("stats.daysWithMusic", "дней с музыкой"))
                figure(summary.longestStreakDays, L("stats.daysStreak", "дней подряд"))
                figure(Int((Double(summary.totalMinutes) / Double(max(summary.activeDays, 1))).rounded()),
                       L("stats.minutesPerDay", "минут в день"))
            }
        }
    }

    private func rankedArtists(_ artists: [ReplayArtist]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(artists.enumerated()), id: \.element.id) { index, artist in
                artistRow(artist, rank: index + 1)
            }
        }
    }

    private func rankedTracks(_ tracks: [ReplayTrack]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                HStack(spacing: 12) {
                    Text("\(index + 1)")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(palette.textColor.opacity(0.45))
                        .frame(width: 24)
                    AsyncCoverImage(url: track.artworkURL, cornerRadius: 12, displaySize: 56)
                        .frame(width: 50, height: 50)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(palette.textColor).lineLimit(1)
                        Text("\(track.plays.spaced) \(L("stats.plays.short", "раз")) · \(track.minutes.spaced) \(L("unit.min", "мин"))")
                            .font(.system(size: 12))
                            .foregroundStyle(palette.secondaryText).lineLimit(1)
                    }
                    Spacer()
                }
                .padding(10)
                .glassEffect(.regular, in: .rect(cornerRadius: 16))
            }
        }
    }

    private func artistRow(_ artist: ReplayArtist, rank: Int) -> some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(palette.textColor.opacity(0.45))
                .frame(width: 26)
            AsyncCoverImage(url: artist.artworkURL, cornerRadius: 26, displaySize: 60)
                .frame(width: 52, height: 52)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(artist.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.textColor).lineLimit(1)
                Text("\(artist.plays.spaced) \(L("stats.plays.short", "раз")) · \(artist.minutes.spaced) \(L("unit.min", "мин"))")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.secondaryText).lineLimit(1)
            }
            Spacer()
        }
        .padding(10)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private func genreCloud(_ genres: [ReplayGenre]) -> some View {
        let total = max(genres.map(\.plays).reduce(0, +), 1)
        return FlowLayout(spacing: 8) {
            ForEach(genres) { genre in
                let share = Double(genre.plays) / Double(total)
                Text(genre.name)
                    .font(.system(size: 14 + share * 12, weight: .semibold))
                    .foregroundStyle(palette.textColor)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .glassEffect(.regular, in: .capsule)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 38))
                .foregroundStyle(palette.textColor.opacity(0.45))
            Text(L("stats.empty", "Здесь пока пусто"))
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(palette.textColor)
            Text(L("stats.emptyHint", "Послушайте что-нибудь — и здесь появится\nваша статистика за этот период"))
                .font(LaxifyTypography.footnote)
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)
            Spacer()
        }
    }

    private func figure(_ value: Int, _ caption: String) -> some View {
        VStack(spacing: 4) {
            Text(value.spaced)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(palette.textColor)
                .minimumScaleFactor(0.6).lineLimit(1)
            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(palette.secondaryText)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(palette.textColor)
    }

    // MARK: - Loading

    private func load() async {
        isLoading = true
        errorMessage = nil

        let local = LocalReplay.bundle(context: modelContext)
        periods = local.periods
        selected = local.current?.period ?? local.periods.first
        if let fresh = local.current {
            summary = fresh
            await refreshPalette(for: fresh)
        }
        isLoading = false

        await HistoryMirror.sync(context: modelContext)

        let merged = LocalReplay.bundle(context: modelContext)
        periods = merged.periods
        selected = merged.current?.period ?? merged.periods.first
        if let fresh = merged.current {
            withAnimation(.easeInOut(duration: 0.3)) { summary = fresh }
            await refreshPalette(for: fresh)
        }
        isLoading = false
    }

    private func select(_ period: ReplayPeriod) {
        guard period.id != selected?.id else { return }
        withAnimation(.snappy(duration: 0.3)) { selected = period }
        Task {
            let local = LocalReplay.summary(period: period, context: modelContext)
            withAnimation(.easeInOut(duration: 0.35)) { summary = local }
            await refreshPalette(for: local)
        }
    }

    private func refreshPalette(for summary: ReplaySummary) async {
        let artwork = summary.topArtists.first?.artworkURL ?? summary.topTracks.first?.artworkURL
        let found = await PaletteExtractor.shared.palette(for: artwork)
        withAnimation(.easeInOut(duration: 0.6)) { palette = found }
    }
}
