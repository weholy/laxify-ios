import Foundation
import SwiftData

/// Brings the account's listening history onto the device.
///
/// Statistics are worked out from what the device recorded, so that they
/// exist whether or not the server can be reached. But a device only knows
/// what it played since this was built — everything before that lives on the
/// server. Without copying it down, the figures jumped between a full history
/// and a nearly empty one depending on the network, which is worse than
/// either.
///
/// So the log is mirrored once, and topped up whenever the server is
/// reachable and has something newer. After that the device is the source the
/// screens read from, and the server only ever adds to it.
@MainActor
enum HistoryMirror {
    private static let lastSyncKey = "laxify.history.mirroredAt"

    /// Copies down anything the device does not already have.
    ///
    /// Safe to call often: it asks only for plays newer than the newest one
    /// held, so a warm device fetches nothing.
    static func sync(context: ModelContext?) async {
        guard let context, await LaxifyAPI.shared.isSignedIn else { return }

        // Only worth attempting when something answers. Otherwise this is a
        // timeout on every launch for no result.
        guard await LaxifyAPI.shared.isServerReachable else { return }

        let newestHeld = newestRecord(in: context)?.playedAt

        guard let plays = try? await LaxifyAPI.shared.playHistory(limit: 2000) else { return }
        guard !plays.isEmpty else {
            UserDefaults.standard.set(Date(), forKey: lastSyncKey)
            return
        }

        // What is already here, so a second run does not double every figure.
        let existing = fingerprints(in: context)
        var added = 0

        for play in plays {
            // The server keeps whole seconds; the device keeps fractions. A
            // fingerprint rounded to the second matches them up.
            let mark = fingerprint(trackId: play.trackId, at: play.playedAt)
            guard !existing.contains(mark) else { continue }

            context.insert(
                PlayRecord(
                    trackId: play.trackId,
                    title: play.title,
                    artistName: play.artistName,
                    artistId: play.artistId,
                    coverURL: play.coverUrl,
                    genre: play.genre,
                    playedAt: play.playedAt,
                    secondsPlayed: play.secondsPlayed,
                    completed: play.completed,
                    isSynced: true
                )
            )
            added += 1
        }

        if added > 0 {
            try? context.save()
            AppLogger.log("history: перенесено записей — \(added)")
            RemoteLog.shared.info(
                "история перенесена на устройство",
                category: "stats",
                context: ["added": "\(added)", "held": newestHeld.map { "\($0)" } ?? "нет"]
            )
        }

        UserDefaults.standard.set(Date(), forKey: lastSyncKey)
    }

    private static func newestRecord(in context: ModelContext) -> PlayRecord? {
        var descriptor = FetchDescriptor<PlayRecord>(
            sortBy: [SortDescriptor(\.playedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// Identifies a play well enough to spot a duplicate.
    private static func fingerprints(in context: ModelContext) -> Set<String> {
        let all = (try? context.fetch(FetchDescriptor<PlayRecord>())) ?? []
        return Set(all.map { fingerprint(trackId: $0.trackId, at: $0.playedAt) })
    }

    private static func fingerprint(trackId: String, at date: Date) -> String {
        "\(trackId)@\(Int(date.timeIntervalSince1970))"
    }
}
