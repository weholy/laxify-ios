import Foundation
import SwiftData

/// Brings old play records up to date without throwing any of them away.
///
/// History recorded before the catalog learned to clean an upload's file name
/// still holds titles like `Lil Peep - Star Shopping (Official Video)` and
/// artists like `☆LiL PEEP☆` — so the statistics screen kept showing the same
/// mangled names no matter how much was listened to. Deleting the records
/// would fix the display and lose the history, which is the wrong trade.
///
/// Two passes instead. The first is local and instant: run every stored title
/// through the cleaner. The second asks the catalog what each track is really
/// called, a capped number per launch, and remembers what it has already
/// asked about so the work finishes over a few sessions and never repeats.
@MainActor
enum StatsRepair {
    private static let repairedKey = "laxify.stats.repairedTrackIds"
    /// Enough to finish a normal history in two or three launches without
    /// making any of them slow.
    private static let perRun = 40

    static func run(context: ModelContext?) async {
        guard let context else { return }

        let records = (try? context.fetch(FetchDescriptor<PlayRecord>())) ?? []
        guard !records.isEmpty else { return }

        cleanTitlesInPlace(records, context: context)
        await refreshFromCatalogue(records, context: context)
    }

    // MARK: - Pass one: the cleaner, offline

    private static func cleanTitlesInPlace(_ records: [PlayRecord], context: ModelContext) {
        var changed = false

        for record in records {
            let cleaned = TrackTitle.clean(record.title)
            if cleaned != record.title {
                record.title = cleaned
                changed = true
            }
        }

        if changed {
            try? context.save()
        }
    }

    // MARK: - Pass two: what the catalogue says now

    private static func refreshFromCatalogue(_ records: [PlayRecord], context: ModelContext) async {
        guard await LaxifyAPI.shared.isServerReachable else { return }

        var repaired = Set(UserDefaults.standard.stringArray(forKey: repairedKey) ?? [])

        // One request per track, not per play: a track listened to forty
        // times is still one question.
        var byTrack: [String: [PlayRecord]] = [:]
        for record in records where !repaired.contains(record.trackId) {
            byTrack[record.trackId, default: []].append(record)
        }

        guard !byTrack.isEmpty else { return }

        var done = 0
        for (trackId, rows) in byTrack {
            guard done < perRun else { break }
            done += 1

            // Marked either way. A track the catalogue no longer carries is
            // not worth asking about again on every launch.
            repaired.insert(trackId)

            guard let song = try? await CatalogService.shared.song(id: trackId) else { continue }

            for row in rows {
                row.title = song.title
                row.artistName = song.artistName
                row.artistId = song.artistId ?? row.artistId
                if let cover = song.coverURL?.absoluteString {
                    row.coverURL = cover
                }
            }
        }

        try? context.save()
        UserDefaults.standard.set(Array(repaired), forKey: repairedKey)

        // Anything on screen showing statistics reads this and redraws.
        NotificationCenter.default.post(name: .laxifyPlayRecorded, object: nil)
    }
}
