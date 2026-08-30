import Foundation

struct LyricLine: Identifiable, Sendable {
    let id = UUID()
    let timestamp: TimeInterval
    let text: String
}

struct Lyrics: Sendable {
    let syncedLines: [LyricLine]
    let plainText: String?
    /// True when the timings were spread evenly over the track rather than
    /// supplied by the source. Good enough to follow along with, but not
    /// accurate enough to fill words one by one — that reads as "the lyrics
    /// are wrong" the moment it drifts.
    var isApproximate: Bool = false

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
            return Lyrics(syncedLines: synthesised, plainText: plain, isApproximate: true)
        }
        return Lyrics(syncedLines: [], plainText: plain)
    }

    /// Spreads plain lines over the track so there is something to follow.
    ///
    /// Weighted by line length rather than evenly: a one-word ad-lib and a
    /// full bar do not take the same time to sing, and an even split drifts
    /// badly by the second verse. Still an estimate — the result is marked
    /// `isApproximate` so the view highlights lines rather than words.
    private static func synthesiseTiming(
        from plain: String, duration: TimeInterval
    ) -> [LyricLine]? {
        guard duration > 40 else { return nil }

        let lines = plain
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.filter({ !$0.isEmpty }).count >= 4 else { return nil }

        // An empty line is a pause; every other line costs a base amount plus
        // a little per syllable-ish unit.
        let weights = lines.map { line -> Double in
            line.isEmpty ? 0.45 : 1.0 + Double(line.count) / 26.0
        }
        let total = weights.reduce(0, +)
        guard total > 0 else { return nil }

        // Music usually starts a beat or two in and outros without words.
        let start = duration * 0.05
        let span = duration * 0.90

        var elapsed = 0.0
        return lines.enumerated().map { index, text in
            let at = start + span * (elapsed / total)
            elapsed += weights[index]
            return LyricLine(timestamp: at, text: text)
        }
    }
}
