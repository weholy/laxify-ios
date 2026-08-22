import Foundation
import SwiftData

/// Saves tracks for offline playback.
///
/// Files live in Application Support rather than Documents so they stay out of
/// the user's Files app, and are marked excluded from iCloud backup — audio is
/// re-downloadable, and backing up a music library would waste the user's
/// iCloud quota.
@MainActor
@Observable
final class DownloadManager {
    static let shared = DownloadManager()

    enum Status: Equatable {
        case none
        case downloading(progress: Double)
        case downloaded
        case failed
    }

    private(set) var statuses: [String: Status] = [:]
    private(set) var totalBytes: Int64 = 0

    private var tasks: [String: Task<Void, Never>] = [:]

    private let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutable = folder
        try? mutable.setResourceValues(resourceValues)

        return folder
    }()

    private init() {
        refreshFromDisk()
    }

    func status(for trackId: String) -> Status {
        statuses[trackId] ?? .none
    }

    func isDownloaded(_ trackId: String) -> Bool {
        status(for: trackId) == .downloaded
    }

    /// Local file for a track, if it has been saved.
    ///
    /// The player consults this before asking the network, which is what makes
    /// a downloaded track play with no connection at all.
    func localURL(for trackId: String) -> URL? {
        let url = fileURL(for: trackId)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func download(_ song: Song) {
        guard tasks[song.id] == nil, !isDownloaded(song.id) else { return }

        statuses[song.id] = .downloading(progress: 0)

        tasks[song.id] = Task { [weak self] in
            guard let self else { return }
            defer { self.tasks[song.id] = nil }

            do {
                let remote = try await CatalogService.shared.streamURL(for: song.id)
                let (temporary, _) = try await URLSession.shared.download(from: remote)

                let destination = self.fileURL(for: song.id)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temporary, to: destination)

                self.statuses[song.id] = .downloaded
                self.refreshFromDisk()

                // Recorded on the account so the set of saved tracks follows
                // the user rather than the handset.
                let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                try? await LaxifyAPI.shared.registerDownload(song: song, sizeBytes: size)
            } catch {
                self.statuses[song.id] = .failed
                AppLogger.log("download: failed for \(song.id) — \(error)")
            }
        }
    }

    func cancel(_ trackId: String) {
        tasks[trackId]?.cancel()
        tasks[trackId] = nil
        statuses[trackId] = .none
    }

    func remove(_ trackId: String) {
        cancel(trackId)
        try? FileManager.default.removeItem(at: fileURL(for: trackId))
        statuses[trackId] = .none
        refreshFromDisk()

        Task { try? await LaxifyAPI.shared.removeDownload(trackId: trackId) }
    }

    func removeAll() {
        for (trackId, _) in statuses where statuses[trackId] == .downloaded {
            try? FileManager.default.removeItem(at: fileURL(for: trackId))
        }
        statuses = [:]
        refreshFromDisk()
    }

    private func fileURL(for trackId: String) -> URL {
        // Track ids contain a colon, which is legal in a path but awkward.
        let safe = trackId.replacingOccurrences(of: ":", with: "_")
        return directory.appendingPathComponent("\(safe).mp3")
    }

    private func refreshFromDisk() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else {
            totalBytes = 0
            return
        }

        var bytes: Int64 = 0
        for file in files {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            bytes += Int64(size)

            let trackId = file.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "_", with: ":")
            statuses[trackId] = .downloaded
        }
        totalBytes = bytes
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }
}
