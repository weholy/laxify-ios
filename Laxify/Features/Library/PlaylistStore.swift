import Foundation

/// The account's playlists, kept in one place so every screen that lists,
/// creates or adds to them stays in step.
///
/// Optimistic: a create or an add shows immediately and is reconciled with
/// the server's answer; a failure rolls back. The list is cached to disk so
/// the library tab paints without waiting for the network.
@MainActor
@Observable
final class PlaylistStore {
    static let shared = PlaylistStore()

    private(set) var playlists: [PlaylistDTO] = []
    private(set) var isLoading = false
    private(set) var lastError: String?

    private var loadedAt: Date?
    private static let freshness: TimeInterval = 5 * 60
    private static let cacheKey = "laxify.playlists.cache"

    private init() {
        playlists = Self.loadCache()
    }

    func loadIfNeeded() async {
        if let loadedAt, Date().timeIntervalSince(loadedAt) < Self.freshness, !playlists.isEmpty {
            return
        }
        await reload()
    }

    func reload() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            playlists = try await LaxifyAPI.shared.myPlaylists()
            loadedAt = Date()
            Self.saveCache(playlists)
        } catch {
            if playlists.isEmpty { lastError = "Не удалось загрузить плейлисты" }
        }
    }

    @discardableResult
    func create(title: String, isPublic: Bool, seed: [Song] = []) async -> PlaylistDTO? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            let created = try await LaxifyAPI.shared.createPlaylist(
                title: trimmed,
                isPublic: isPublic,
                tracks: seed.map(BackendTrack.init(song:))
            )
            playlists.insert(created.summary, at: 0)
            Self.saveCache(playlists)
            return created.summary
        } catch {
            lastError = "Не удалось создать плейлист"
            return nil
        }
    }

    func rename(_ playlist: PlaylistDTO, to title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != playlist.title else { return }
        guard let updated = try? await LaxifyAPI.shared.renamePlaylist(id: playlist.id, title: trimmed) else {
            lastError = "Не удалось переименовать"
            return
        }
        replace(updated)
    }

    func delete(_ playlist: PlaylistDTO) async {
        let snapshot = playlists
        playlists.removeAll { $0.id == playlist.id }
        Self.saveCache(playlists)
        do {
            try await LaxifyAPI.shared.deletePlaylist(id: playlist.id)
        } catch {
            playlists = snapshot
            Self.saveCache(playlists)
            lastError = "Не удалось удалить плейлист"
        }
    }

    func add(_ songs: [Song], to playlist: PlaylistDTO) async {
        guard !songs.isEmpty else { return }
        do {
            try await LaxifyAPI.shared.addTracks(
                playlistId: playlist.id,
                tracks: songs.map(BackendTrack.init(song:))
            )
            // The count the list shows is worth keeping roughly right without
            // a full refetch.
            bumpCount(playlist.id, by: songs.count)
        } catch {
            lastError = "Не удалось добавить в плейлист"
        }
    }

    func removeTrack(_ trackId: String, from playlistId: String) async {
        guard (try? await LaxifyAPI.shared.removeTrack(playlistId: playlistId, trackId: trackId)) != nil else {
            lastError = "Не удалось убрать трек"
            return
        }
        bumpCount(playlistId, by: -1)
    }

    // MARK: - Helpers

    private func replace(_ updated: PlaylistDTO) {
        if let index = playlists.firstIndex(where: { $0.id == updated.id }) {
            playlists[index] = updated
            Self.saveCache(playlists)
        }
    }

    private func bumpCount(_ id: String, by delta: Int) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        let current = playlists[index]
        playlists[index] = PlaylistDTO(
            id: current.id, title: current.title, description: current.description,
            coverUrl: current.coverUrl, isPublic: current.isPublic, shareSlug: current.shareSlug,
            trackCount: max(0, current.trackCount + delta),
            totalDurationSeconds: current.totalDurationSeconds, updatedAt: Date()
        )
        Self.saveCache(playlists)
    }

    private static func loadCache() -> [PlaylistDTO] {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let decoded = try? JSONDecoder.laxify.decode([PlaylistDTO].self, from: data) else {
            return []
        }
        return decoded
    }

    private static func saveCache(_ playlists: [PlaylistDTO]) {
        guard let data = try? JSONEncoder.laxify.encode(playlists) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
    }
}

/// Coders that match the server's snake_case + ISO-8601 wire format, so the
/// on-disk cache round-trips the same DTOs the API returns.
extension JSONDecoder {
    static let laxify: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension JSONEncoder {
    static let laxify: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
