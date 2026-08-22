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
        return Lyrics(syncedLines: [], plainText: plain)
    }
}
