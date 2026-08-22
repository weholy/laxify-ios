import Foundation
import SwiftData

/// Keeps the on-device library and the account in step.
///
/// The local store stays the thing the UI reads, so everything still works
/// offline; this service pushes changes up and pulls the server's version
/// down when there is a connection.
@MainActor
@Observable
final class SyncService {
    static let shared = SyncService()

    private(set) var isSyncing = false
    private(set) var lastSyncedAt: Date?

    /// Play events are batched rather than sent one by one: a phone coming
    /// back from a tunnel should flush its backlog in a single request.
    private var pendingPlayback: [PlaybackEvent] = []
    private var flushTask: Task<Void, Never>?

    private init() {}

    // MARK: - Favourites

    func favoriteAdded(_ song: Song) {
        Task { try? await LaxifyAPI.shared.addFavorite(song) }
    }

    func favoriteRemoved(trackId: String) {
        Task { try? await LaxifyAPI.shared.removeFavorite(trackId: trackId) }
    }

    func dislikeAdded(trackId: String) {
        Task { try? await LaxifyAPI.shared.addDislike(trackId: trackId) }
    }

    /// Pulls the server's library into the local store.
    ///
    /// The server wins on conflicts: it is the copy shared across devices, and
    /// a phone that was offline for a week should not resurrect tracks the
    /// user removed elsewhere.
    func pullLibrary(into context: ModelContext) async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        guard let remote = try? await LaxifyAPI.shared.favorites() else { return }

        let existing = (try? context.fetch(FetchDescriptor<FavoriteTrack>())) ?? []
        let existingById = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        let remoteIds = Set(remote.map(\.track.trackId))

        for favorite in remote where existingById[favorite.track.trackId] == nil {
            context.insert(FavoriteTrack(song: favorite.track.song, addedAt: favorite.addedAt))
        }

        for local in existing where !remoteIds.contains(local.id) {
            context.delete(local)
        }

        if let remoteDislikes = try? await LaxifyAPI.shared.dislikes() {
            let localDislikes = (try? context.fetch(FetchDescriptor<DislikedTrack>())) ?? []
            let localIds = Set(localDislikes.map(\.id))

            for trackId in remoteDislikes where !localIds.contains(trackId) {
                context.insert(DislikedTrack(id: trackId))
            }
        }

        lastSyncedAt = .now
    }

    // MARK: - Playback

    func recordPlayback(song: Song, seconds: Double, completed: Bool, source: String?) {
        guard seconds > 0 else { return }

        pendingPlayback.append(
            PlaybackEvent(
                track: BackendTrack(song: song),
                playedAt: Date(),
                secondsPlayed: seconds,
                completed: completed,
                source: source
            )
        )

        scheduleFlush()
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }

        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            await self?.flushPlayback()
        }
    }

    func flushPlayback() async {
        flushTask = nil
        guard !pendingPlayback.isEmpty else { return }

        let batch = pendingPlayback
        pendingPlayback = []

        do {
            try await LaxifyAPI.shared.reportPlayback(batch)
        } catch {
            // Keep the events for the next attempt rather than losing them,
            // but cap the backlog so a long outage cannot grow without bound.
            pendingPlayback = Array((batch + pendingPlayback).suffix(400))
        }
    }
}
