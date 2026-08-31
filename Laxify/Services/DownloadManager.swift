import Foundation
import SwiftData

/// Keeping tracks on the device.
///
/// Files go to Application Support rather than Documents, so they stay out of
/// the Files app, and are excluded from iCloud backup — a music library is
/// re-downloadable and has no business in someone's backup quota.
///
/// Progress is published per track so any row, anywhere, can draw the same
/// download in flight; the actual work is one `Task` per track, kept here so a
/// second tap cancels rather than starting a duplicate.
@MainActor
@Observable
final class DownloadManager {
    static let shared = DownloadManager()

    /// Track id → 0…1 while a download is running. Absent means idle.
    private(set) var progress: [String: Double] = [:]

    /// Set once at launch, the same way the player gets its context.
    var modelContext: ModelContext?

    /// Ids known to be on disk. Mirrors the store so a row can ask without
    /// touching SwiftData on every render.
    private(set) var saved: Set<String> = []

    private var tasks: [String: Task<Void, Never>] = [:]

    private init() {}

    // MARK: - Where the files live

    /// The local file for a track, or nil if it isn't here. Callable from
    /// anywhere — the player asks this off the main actor, before it decides
    /// whether it needs the network at all.
    nonisolated static func localURL(for trackId: String) -> URL? {
        DownloadStore.localURL(for: trackId)
    }

    // MARK: - State

    func isDownloaded(_ trackId: String) -> Bool {
        saved.contains(trackId)
    }

    func isDownloading(_ trackId: String) -> Bool {
        progress[trackId] != nil
    }

    /// Reads the store once at launch so `saved` is warm.
    func refreshSaved() {
        guard let modelContext else { return }
        let rows = (try? modelContext.fetch(FetchDescriptor<DownloadedTrack>())) ?? []
        saved = Set(rows.map(\.id))
    }

    // MARK: - Downloading

    /// Saves one track. Already here, or already running: nothing happens.
    func download(_ song: Song) {
        guard !saved.contains(song.id), tasks[song.id] == nil else { return }

        progress[song.id] = 0
        tasks[song.id] = Task { [weak self] in
            await self?.perform(song)
            self?.tasks[song.id] = nil
        }
    }

    /// Saves a whole list, one at a time.
    ///
    /// Sequential on purpose: ten parallel downloads on a phone's connection
    /// finish no sooner and make every individual percentage crawl, which is
    /// the number the screen is showing.
    func download(_ songs: [Song]) {
        let pending = songs.filter { !saved.contains($0.id) && tasks[$0.id] == nil }
        guard !pending.isEmpty else { return }

        for song in pending {
            progress[song.id] = 0
        }

        batchTotal = pending.count
        batchDone = 0

        let batchKey = Self.batchKey
        tasks[batchKey]?.cancel()
        tasks[batchKey] = Task { [weak self] in
            for song in pending {
                guard !Task.isCancelled else { break }
                await self?.perform(song)
                self?.batchDone += 1
            }
            self?.batchTotal = 0
            self?.batchDone = 0
            self?.tasks[batchKey] = nil
        }
    }

    /// How far a whole-list download has got, 0…1, or nil when none is
    /// running.
    ///
    /// Counted against the size of the batch rather than averaged over what
    /// is left: a finished track drops out of `progress`, so averaging the
    /// remainder made the number fall back towards zero every time one
    /// completed.
    var batchProgress: Double? {
        guard batchTotal > 0 else {
            // A single track still deserves a ring.
            return progress.values.max()
        }
        let inFlight = progress.values.reduce(0, +)
        return min(1, (Double(batchDone) + inFlight) / Double(batchTotal))
    }

    func cancelAll() {
        for (_, task) in tasks { task.cancel() }
        tasks.removeAll()
        progress.removeAll()
        batchTotal = 0
        batchDone = 0
    }

    private var batchTotal = 0
    private var batchDone = 0

    private static let batchKey = "__batch__"

    private func perform(_ song: Song) async {
        defer { progress[song.id] = nil }

        guard let source = try? await CatalogService.shared.streamURL(for: song.id) else {
            AppLogger.log("скачивание: нет ссылки для \(song.id)")
            return
        }

        let id = song.id
        let delegate = DownloadProgressDelegate { fraction in
            Task { @MainActor in
                DownloadManager.shared.progress[id] = fraction
            }
        }

        do {
            let (temporary, _) = try await URLSession.shared.download(from: source, delegate: delegate)
            guard !Task.isCancelled else {
                try? FileManager.default.removeItem(at: temporary)
                return
            }

            let destination = DownloadStore.fileURL(for: id)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)

            let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            record(song, byteCount: size)
        } catch {
            AppLogger.log("скачивание не удалось: \(song.title) — \(error.localizedDescription)")
        }
    }

    private func record(_ song: Song, byteCount: Int) {
        guard let modelContext else { return }

        let id = song.id
        let existing = try? modelContext.fetch(
            FetchDescriptor<DownloadedTrack>(predicate: #Predicate { $0.id == id })
        )
        if let row = existing?.first {
            row.byteCount = byteCount
            row.savedAt = .now
        } else {
            modelContext.insert(DownloadedTrack(song: song, byteCount: byteCount))
        }
        try? modelContext.save()
        saved.insert(id)
    }

    // MARK: - Removing

    /// Forgets one track: the row and the file both.
    func remove(_ trackId: String) {
        tasks[trackId]?.cancel()
        tasks[trackId] = nil
        progress[trackId] = nil

        if let url = Self.localURL(for: trackId) {
            try? FileManager.default.removeItem(at: url)
        }

        if let modelContext {
            let rows = (try? modelContext.fetch(
                FetchDescriptor<DownloadedTrack>(predicate: #Predicate { $0.id == trackId })
            )) ?? []
            for row in rows { modelContext.delete(row) }
            try? modelContext.save()
        }

        saved.remove(trackId)
    }

    /// Empties the library — rows, files and all.
    func removeAll() {
        cancelAll()

        if let contents = try? FileManager.default.contentsOfDirectory(
            at: DownloadStore.directory, includingPropertiesForKeys: nil
        ) {
            for file in contents { try? FileManager.default.removeItem(at: file) }
        }

        if let modelContext {
            let rows = (try? modelContext.fetch(FetchDescriptor<DownloadedTrack>())) ?? []
            for row in rows { modelContext.delete(row) }
            try? modelContext.save()
        }

        saved.removeAll()
    }

    /// What the whole library costs on disk.
    var totalBytes: Int {
        guard let modelContext else { return 0 }
        let rows = (try? modelContext.fetch(FetchDescriptor<DownloadedTrack>())) ?? []
        return rows.reduce(0) { $0 + $1.byteCount }
    }
}

/// Reports how far a download has got.
///
/// `URLSession.download(from:delegate:)` handles the finished file itself, but
/// still forwards write callbacks — which is the only way to get a percentage
/// out of the async API.
private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    /// Never called on the async path, but the protocol insists on it.
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}
}

/// Where downloaded audio lives on disk.
///
/// Deliberately outside the manager: the player reads this from whatever
/// context it happens to be on, and a main-actor type cannot be asked a
/// question off the main actor.
enum DownloadStore {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var folder = base.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // A music library is re-downloadable; it has no business in someone's
        // iCloud backup quota.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)

        return folder
    }()

    /// A file name that survives whatever a catalog puts in a track id.
    static func fileURL(for trackId: String) -> URL {
        let safe = String(trackId.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        })
        return directory.appendingPathComponent(safe + ".mp3")
    }

    static func localURL(for trackId: String) -> URL? {
        let url = fileURL(for: trackId)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
