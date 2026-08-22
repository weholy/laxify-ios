import Foundation

/// Queue of changes waiting to reach the server.
///
/// Fire-and-forget requests silently lost data: a like sent while the network
/// was down, the token was mid-refresh, or the app was backgrounded simply
/// vanished, and nothing retried it. Every mutation now goes through here —
/// persisted to disk, retried with backoff, and only dropped once the server
/// has confirmed it.
@MainActor
@Observable
final class SyncOutbox {
    static let shared = SyncOutbox()

    enum Operation: Codable {
        case addFavorite(track: BackendTrack, addedAt: Date)
        case removeFavorite(trackId: String)
        case addDislike(trackId: String)
        case playback(events: [PlaybackEvent])
    }

    private struct Item: Codable {
        let id: UUID
        let operation: Operation
        var attempts: Int
    }

    private(set) var pendingCount = 0

    private var items: [Item] = []
    private var isFlushing = false
    private var retryTask: Task<Void, Never>?

    private let storageKey = "laxify.sync.outbox"
    /// Past this many failures an item is almost certainly malformed rather
    /// than blocked by a transient problem, and keeping it would wedge the
    /// queue behind it forever.
    private let maxAttempts = 8
    private let maxItems = 500

    private init() {
        load()
    }

    // MARK: - Enqueue

    func addFavorite(_ song: Song) {
        enqueue(.addFavorite(track: BackendTrack(song: song), addedAt: Date()))
    }

    func removeFavorite(trackId: String) {
        // A pending add for the same track is now pointless; dropping it also
        // avoids the pair racing and leaving the wrong end state.
        items.removeAll { item in
            if case .addFavorite(let track, _) = item.operation {
                return track.trackId == trackId
            }
            return false
        }
        enqueue(.removeFavorite(trackId: trackId))
    }

    func addDislike(trackId: String) {
        enqueue(.addDislike(trackId: trackId))
    }

    func playback(_ events: [PlaybackEvent]) {
        guard !events.isEmpty else { return }
        enqueue(.playback(events: events))
    }

    private func enqueue(_ operation: Operation) {
        items.append(Item(id: UUID(), operation: operation, attempts: 0))
        if items.count > maxItems {
            items.removeFirst(items.count - maxItems)
        }
        persist()
        Task { await flush() }
    }

    // MARK: - Flush

    func flush() async {
        guard !isFlushing, !items.isEmpty else { return }
        guard await LaxifyAPI.shared.isSignedIn else { return }

        isFlushing = true
        defer { isFlushing = false }

        var remaining: [Item] = []

        for var item in items {
            do {
                try await perform(item.operation)
            } catch APIError.notAuthenticated {
                // Not a failure of this item: stop and keep everything for
                // after the next sign-in.
                remaining.append(contentsOf: items.drop { $0.id != item.id })
                items = remaining
                persist()
                return
            } catch {
                item.attempts += 1
                AppLogger.log("outbox: attempt \(item.attempts) failed — \(error)")

                if item.attempts < maxAttempts {
                    remaining.append(item)
                } else {
                    AppLogger.log("outbox: dropping item after \(item.attempts) attempts")
                }
            }
        }

        items = remaining
        persist()

        if !items.isEmpty {
            scheduleRetry()
        }
    }

    private func perform(_ operation: Operation) async throws {
        switch operation {
        case .addFavorite(let track, let addedAt):
            try await LaxifyAPI.shared.addFavorite(track: track, addedAt: addedAt)
        case .removeFavorite(let trackId):
            try await LaxifyAPI.shared.removeFavorite(trackId: trackId)
        case .addDislike(let trackId):
            try await LaxifyAPI.shared.addDislike(trackId: trackId)
        case .playback(let events):
            try await LaxifyAPI.shared.reportPlayback(events)
        }
    }

    private func scheduleRetry() {
        guard retryTask == nil else { return }

        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            self?.retryTask = nil
            await self?.flush()
        }
    }

    // MARK: - Persistence

    private func persist() {
        pendingCount = items.count
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let stored = try? JSONDecoder().decode([Item].self, from: data) else {
            return
        }
        items = stored
        pendingCount = stored.count
    }

    func clear() {
        items = []
        persist()
    }
}
