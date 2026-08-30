import Foundation

struct LyricLine: Identifiable, Sendable {
    let id = UUID()
    let timestamp: TimeInterval
    let text: String
}

struct Lyrics: Sendable {
    let syncedLines: [LyricLine]
    let plainText: String?

    /// One line is a title card, not something worth following.
    var isSynced: Bool { syncedLines.count > 1 }
}

enum LyricsService {
    /// Tries progressively looser lookups: an exact duration-matched hit is
    /// best, but lesser-known tracks are often only indexed under a slightly
    /// different title/artist spelling, or with no duration at all, so fall
    /// back to search before giving up.
    /// Words for a track, from our own server.
    ///
    /// The lookup moved off the phone: one source rarely has everything, and
    /// trying several from every device would mean the same misses searched
    /// again on every play. The server tries each source in turn and keeps
    /// what it finds — including the fact that a track has none — so a source
    /// can be added later without shipping an app.
    static func fetch(trackId: String, title: String, artistName: String, duration: TimeInterval) async -> Lyrics? {
        guard let payload = try? await LaxifyAPI.shared.lyrics(
            trackId: trackId, title: title, artist: artistName, duration: duration
        ), payload.found else {
            return nil
        }

        let lines = payload.synced.map { LyricLine(timestamp: $0.timestamp, text: $0.text) }

        // A single line is a title card, not a lyric worth following.
        if lines.count > 1 {
            return Lyrics(syncedLines: lines, plainText: payload.plain)
        }

        guard let plain = payload.plain, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        // No timed lyrics for this track. Rather than a static wall of text,
        // lay the lines out evenly across the song so the reader still gets a
        // moving highlight and follow-along scroll. Approximate, but it reads
        // as the same feature everywhere else has.
        if let synthesised = synthesiseTiming(from: plain, duration: duration) {
            return Lyrics(syncedLines: synthesised, plainText: plain)
        }
        return Lyrics(syncedLines: [], plainText: plain)
    }

    private static func synthesiseTiming(
        from plain: String, duration: TimeInterval
    ) -> [LyricLine]? {
        guard duration > 40 else { return nil }

        let lines = plain
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // Keep blank lines as breath marks, but need real content to bother.
        guard lines.filter({ !$0.isEmpty }).count >= 4 else { return nil }

        let start = duration * 0.06
        let end = duration * 0.94
        let step = (end - start) / Double(max(lines.count - 1, 1))

        return lines.enumerated().map { index, text in
            LyricLine(timestamp: start + step * Double(index), text: text)
        }
    }
}
