import Foundation
import SwiftData

/// Gets every play to the server, eventually.
///
/// Plays used to sit in memory for twenty seconds before they were persisted
/// anywhere, so closing the app inside that window lost them. The queue they
/// then joined gave up after eight failed attempts — which, with the server
/// unreachable for hours, meant a whole evening of listening was discarded
/// rather than delayed.
///
/// Now the record written at play time *is* the queue. It is on disk before
/// anything else happens, and it is marked as sent only once the server has
/// confirmed it. Nothing is ever dropped for failing: an unreachable server
/// is a reason to wait, not a reason to forget.
@MainActor
enum PlaybackUploader {
    /// Large enough that a backlog clears in a few requests, small enough
    /// that one failure does not cost much.
    private static let batchSize = 100

    private static var isUploading = false

    /// Sends everything the server has not confirmed.
    static func flush(context: ModelContext?) async {
        guard let context, !isUploading else { return }
        guard await LaxifyAPI.shared.isSignedIn else { return }
        guard await LaxifyAPI.shared.isServerReachable else { return }

        isUploading = true
        defer { isUploading = false }

        while true {
            let pending = unsent(in: context, limit: batchSize)
            guard !pending.isEmpty else { return }

            let events = pending.map { record in
                PlaybackEvent(
                    track: BackendTrack(
                        trackId: record.trackId,
                        title: record.title,
                        artistName: record.artistName,
                        artistId: record.artistId,
                        albumTitle: nil,
                        albumId: nil,
                        coverUrl: record.coverURL,
                        durationSeconds: 0,
                        genre: record.genre
                    ),
                    playedAt: record.playedAt,
                    secondsPlayed: record.secondsPlayed,
                    completed: record.completed,
                    source: "device"
                )
            }

            do {
                try await LaxifyAPI.shared.reportPlayback(events)
            } catch {
                // Left unsent on purpose. The next attempt will find them
                // again, however long that takes.
                RemoteLog.shared.warn(
                    "прослушивания не ушли, останутся в очереди",
                    category: "stats",
                    context: ["count": "\(pending.count)", "error": "\(error)"]
                )
                return
            }

            for record in pending {
                record.isSynced = true
            }
            try? context.save()

            RemoteLog.shared.info(
                "прослушивания отправлены",
                category: "stats",
                context: ["count": "\(pending.count)"]
            )

            // A short batch means the backlog is cleared.
            if pending.count < batchSize { return }
        }
    }

    /// How much is waiting, for the diagnostics screen.
    static func pendingCount(context: ModelContext?) -> Int {
        guard let context else { return 0 }

        let descriptor = FetchDescriptor<PlayRecord>(
            predicate: #Predicate { !$0.isSynced }
        )
        return (try? context.fetchCount(descriptor)) ?? 0
    }

    private static func unsent(in context: ModelContext, limit: Int) -> [PlayRecord] {
        var descriptor = FetchDescriptor<PlayRecord>(
            predicate: #Predicate { !$0.isSynced },
            sortBy: [SortDescriptor(\.playedAt)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }
}
