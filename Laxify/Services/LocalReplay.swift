import Foundation
import SwiftData

/// Listening statistics worked out on the device.
///
/// The server computes these too, and better — it sees every device someone
/// uses. But it cannot always be reached, and statistics that vanish with the
/// network are not statistics. So the same figures are derived from what this
/// device recorded, and the server's version replaces them whenever it
/// arrives.
///
/// Months are bounded by the device's own clock, so a month begins at
/// midnight where the listener is rather than wherever the server happens to
/// be.
@MainActor
enum LocalReplay {
    /// Below this a play is a skip, and counting it flatters every figure.
    private static let meaningfulSeconds: Double = 30

    private static let months = [
        "Январь", "Февраль", "Март", "Апрель", "Май", "Июнь",
        "Июль", "Август", "Сентябрь", "Октябрь", "Ноябрь", "Декабрь"
    ]

    private static let shortMonths = [
        "Янв", "Фев", "Мар", "Апр", "Май", "Июн",
        "Июл", "Авг", "Сен", "Окт", "Ноя", "Дек"
    ]

    // MARK: - Recording

    static func record(
        _ song: Song, seconds: Double, completed: Bool, context: ModelContext?
    ) {
        guard let context, seconds > 3 else { return }

        context.insert(
            PlayRecord(
                trackId: song.id,
                title: song.title,
                artistName: song.artistName,
                artistId: song.artistId,
                coverURL: song.coverURL?.absoluteString,
                playedAt: Date(),
                secondsPlayed: seconds,
                completed: completed
            )
        )

        try? context.save()
    }

    // MARK: - Reading

    /// The months this device has anything in, newest first, plus all-time.
    static func periods(context: ModelContext?) -> [ReplayPeriod] {
        let plays = meaningful(context)
        guard !plays.isEmpty else { return [currentPeriod()] }

        let calendar = Calendar.current
        var seen: [DateComponents] = []

        for play in plays {
            let parts = calendar.dateComponents([.year, .month], from: play.playedAt)
            if !seen.contains(where: { $0.year == parts.year && $0.month == parts.month }) {
                seen.append(parts)
            }
        }

        let sorted = seen.sorted {
            ($0.year ?? 0, $0.month ?? 0) > ($1.year ?? 0, $1.month ?? 0)
        }

        let now = calendar.dateComponents([.year, .month], from: Date())

        var result = sorted.compactMap { parts -> ReplayPeriod? in
            guard let year = parts.year, let month = parts.month else { return nil }
            return period(year: year, month: month, isCurrent: year == now.year && month == now.month)
        }

        // The current month always appears, even before anything is played in
        // it — otherwise the card disappears on the first of every month.
        if !result.contains(where: \.isCurrent) {
            result.insert(currentPeriod(), at: 0)
        }

        result.append(ReplayPeriod(id: "all", title: "За всё время", shortTitle: "Всё"))
        return result
    }

    /// The figures for one period.
    static func summary(period: ReplayPeriod, context: ModelContext?, limit: Int = 10) -> ReplaySummary {
        let plays = meaningful(context).filter { within(period, $0.playedAt) }

        let seconds = plays.reduce(0) { $0 + $1.secondsPlayed }

        // Grouped by whoever was credited: an artist without an id is still
        // an artist, and dropping them would undercount the very people
        // someone listens to most.
        var byArtist: [String: (name: String, cover: String?, seconds: Double, plays: Int)] = [:]
        var byTrack: [String: (record: PlayRecord, plays: Int, seconds: Double)] = [:]

        for play in plays {
            let artistKey = play.artistId ?? play.artistName
            var artist = byArtist[artistKey] ?? (play.artistName, play.coverURL, 0, 0)
            artist.seconds += play.secondsPlayed
            artist.plays += 1
            if artist.cover == nil { artist.cover = play.coverURL }
            byArtist[artistKey] = artist

            var track = byTrack[play.trackId] ?? (play, 0, 0)
            track.plays += 1
            track.seconds += play.secondsPlayed
            byTrack[play.trackId] = track
        }

        let topArtists = byArtist
            .sorted { $0.value.seconds > $1.value.seconds }
            .prefix(limit)
            .map { key, value in
                ReplayArtist(
                    id: key,
                    name: value.name,
                    artworkUrl: value.cover,
                    minutes: Int(value.seconds / 60),
                    plays: value.plays
                )
            }

        let topTracks = byTrack
            .sorted { ($0.value.plays, $0.value.seconds) > ($1.value.plays, $1.value.seconds) }
            .prefix(limit)
            .map { _, value in
                ReplayTrack(
                    id: value.record.trackId,
                    title: value.record.title,
                    artistName: value.record.artistName,
                    artworkUrl: value.record.coverURL,
                    plays: value.plays,
                    minutes: Int(value.seconds / 60)
                )
            }

        let genres = Dictionary(grouping: plays.compactMap(\.genre)) { $0 }
            .map { ReplayGenre(name: $0.key, plays: $0.value.count) }
            .sorted { $0.plays > $1.plays }
            .prefix(6)

        let days = Set(plays.map { Calendar.current.startOfDay(for: $0.playedAt) })

        return ReplaySummary(
            period: period,
            totalMinutes: Int(seconds / 60),
            totalPlays: plays.count,
            distinctTracks: byTrack.count,
            distinctArtists: byArtist.count,
            topArtists: Array(topArtists),
            topTracks: Array(topTracks),
            genres: Array(genres),
            activeDays: days.count,
            longestStreakDays: longestStreak(in: days)
        )
    }

    /// Everything the screen opens with, without a round trip.
    static func bundle(context: ModelContext?, limit: Int = 10) -> ReplayBundle {
        let available = periods(context: context)
        let months = available.filter { $0.id != "all" }

        let opening = months.first(where: \.isCurrent) ?? months.first
        let earlier = months.first { $0.id != opening?.id }

        return ReplayBundle(
            periods: available,
            current: opening.map { summary(period: $0, context: context, limit: limit) },
            previous: earlier.map { summary(period: $0, context: context, limit: limit) }
        )
    }

    // MARK: - Pieces

    private static func meaningful(_ context: ModelContext?) -> [PlayRecord] {
        guard let context else { return [] }

        let threshold = meaningfulSeconds
        let descriptor = FetchDescriptor<PlayRecord>(
            predicate: #Predicate { $0.secondsPlayed >= threshold },
            sortBy: [SortDescriptor(\.playedAt, order: .reverse)]
        )

        return (try? context.fetch(descriptor)) ?? []
    }

    private static func currentPeriod() -> ReplayPeriod {
        let parts = Calendar.current.dateComponents([.year, .month], from: Date())
        return period(year: parts.year ?? 2026, month: parts.month ?? 1, isCurrent: true)
    }

    private static func period(year: Int, month: Int, isCurrent: Bool) -> ReplayPeriod {
        let name = months[max(min(month, 12), 1) - 1]
        let short = shortMonths[max(min(month, 12), 1) - 1]
        let thisYear = Calendar.current.component(.year, from: Date())

        return ReplayPeriod(
            id: String(format: "%04d-%02d", year, month),
            // The year is only worth saying when it is not this one.
            title: year == thisYear ? name : "\(name) \(year)",
            shortTitle: short,
            isCurrent: isCurrent
        )
    }

    private static func within(_ period: ReplayPeriod, _ date: Date) -> Bool {
        guard period.id != "all" else { return true }

        let parts = period.id.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2 else { return true }

        let actual = Calendar.current.dateComponents([.year, .month], from: date)
        return actual.year == parts[0] && actual.month == parts[1]
    }

    private static func longestStreak(in days: Set<Date>) -> Int {
        guard !days.isEmpty else { return 0 }

        let ordered = days.sorted()
        var longest = 1
        var run = 1

        for (previous, current) in zip(ordered, ordered.dropFirst()) {
            let gap = Calendar.current.dateComponents([.day], from: previous, to: current).day ?? 0
            if gap == 1 {
                run += 1
                longest = max(longest, run)
            } else {
                run = 1
            }
        }

        return longest
    }
}
