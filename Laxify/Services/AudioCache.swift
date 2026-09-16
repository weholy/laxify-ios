import Foundation

/// Keeps what you have actually listened to, so the second play is instant.
///
/// Invisible on purpose. There is no screen for it, no setting and no number
/// anywhere — a track you played once simply starts immediately the next
/// time, and that is the whole feature. Explicit downloads are a different
/// thing entirely and live in `DownloadStore`; this never touches them.
///
/// Three rules keep it from becoming a problem:
///   • only tracks heard for thirty seconds are kept — a skip is not a listen
///   • at most 500 MB, oldest first out
///   • wiped weekly, so a stale copy of a track whose source has changed
///     cannot outlive the week
enum AudioCache {
    private static let limitBytes = 500 * 1024 * 1024
    private static let week: TimeInterval = 60 * 60 * 24 * 7
    private static let sweptAtKey = "laxify.audioCache.sweptAt"
    /// A listen, not a glance.
    private static let keepAfterSeconds: TimeInterval = 30

    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var folder = base.appendingPathComponent("AudioCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)

        return folder
    }()

    private static func fileURL(for trackId: String) -> URL {
        let safe = String(trackId.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        })
        return directory.appendingPathComponent(safe + ".mp3")
    }

    /// A cached copy, if there is one. Cheap enough to ask on every play.
    static func localURL(for trackId: String) -> URL? {
        let url = fileURL(for: trackId)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Throws away the copy of one track.
    ///
    /// Called when the player could not open it. A file here is only ever
    /// consulted before the network, so a bad one is not a slow track, it is
    /// a track that can never play again — and the weekly sweep was the only
    /// thing that ever cleared one.
    static func forget(_ trackId: String) {
        try? FileManager.default.removeItem(at: fileURL(for: trackId))
    }

    // MARK: - Filling it

    private static let inFlight = InFlight()

    /// Called as a track plays. Does nothing until it has been heard long
    /// enough to be worth keeping, and nothing at all if it is already here
    /// or already saved as a proper download.
    static func note(_ song: Song, playedFor seconds: TimeInterval) {
        guard seconds >= keepAfterSeconds else { return }
        guard DownloadStore.localURL(for: song.id) == nil else { return }
        guard localURL(for: song.id) == nil else { return }

        Task.detached(priority: .background) {
            guard await inFlight.begin(song.id) else { return }
            defer { Task { await inFlight.end(song.id) } }

            guard let source = try? await CatalogService.shared.streamURL(for: song.id),
                  let (temporary, response) = try? await URLSession.shared.download(from: source)
            else { return }

            // What came back has to be audio before it is kept.
            //
            // This was written down unexamined, and a signed link that had
            // lapsed by the time this ran — which is exactly when this runs,
            // half a minute into a track — returns a few hundred bytes of
            // refusal with a perfectly ordinary "no error". That got saved as
            // the track. From then on it was found before the network on
            // every play, opened instantly, failed instantly, and the song
            // was skipped every single time until the weekly sweep. One
            // unlucky moment, a week of a song that "just gets skipped".
            guard AudioPayload.isPlausible(response, at: temporary) else {
                try? FileManager.default.removeItem(at: temporary)
                return
            }

            let destination = fileURL(for: song.id)
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.moveItem(at: temporary, to: destination)

            trim()
        }
    }

    // MARK: - Keeping it small and fresh

    /// Wipes everything once a week. Called at launch.
    ///
    /// A media host's links, and sometimes its files, do not stay the same
    /// forever; a cache that never forgets eventually serves something the
    /// catalogue no longer agrees with.
    static func sweepIfDue() {
        let last = UserDefaults.standard.double(forKey: sweptAtKey)
        let now = Date().timeIntervalSince1970

        guard last > 0 else {
            UserDefaults.standard.set(now, forKey: sweptAtKey)
            return
        }
        guard now - last > week else { return }

        if let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) {
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
        UserDefaults.standard.set(now, forKey: sweptAtKey)
    }

    /// Drops the least recently used files until the cache is under the cap.
    private static func trim() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentAccessDateKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys
        ) else { return }

        var entries: [(url: URL, size: Int, used: Date)] = []
        var total = 0

        for file in files {
            let values = try? file.resourceValues(forKeys: Set(keys))
            let size = values?.fileSize ?? 0
            let used = values?.contentAccessDate ?? values?.contentModificationDate ?? .distantPast
            entries.append((file, size, used))
            total += size
        }

        guard total > limitBytes else { return }

        for entry in entries.sorted(by: { $0.used < $1.used }) {
            guard total > limitBytes else { break }
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}

/// Whether what a download returned is actually audio.
///
/// `URLSession.download` reports no error for a 403, a 404 or a JSON refusal
/// — it fetched the response it was asked for, and that response happened not
/// to be music. Both places that save a file to disk used to take it on
/// faith, and a file saved on faith is consulted before the network on every
/// later play: one lapsed link is a track that "just gets skipped" for as
/// long as the file survives.
enum AudioPayload {
    /// Smaller than any real track and larger than any error page. The
    /// shortest thing in the catalogue worth playing runs a few seconds at
    /// 128 kbps, which is hundreds of kilobytes; a refusal is hundreds of
    /// bytes.
    private static let smallestPlausible = 48 * 1024

    static func isPlausible(_ response: URLResponse?, at url: URL) -> Bool {
        if let http = response as? HTTPURLResponse {
            guard (200..<300).contains(http.statusCode) else { return false }

            let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            if type.contains("json") || type.contains("xml") || type.hasPrefix("text/") {
                return false
            }
        }

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return size >= smallestPlausible
    }
}

/// Which tracks are being fetched right now, so a second tick does not start
/// the same download again.
private actor InFlight {
    private var ids: Set<String> = []

    func begin(_ id: String) -> Bool {
        guard !ids.contains(id) else { return false }
        ids.insert(id)
        return true
    }

    func end(_ id: String) {
        ids.remove(id)
    }
}
