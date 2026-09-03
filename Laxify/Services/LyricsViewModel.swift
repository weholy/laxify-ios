import Foundation
import AVFoundation

@MainActor
@Observable
final class LyricsViewModel {
    private(set) var lyrics: Lyrics?
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private var loadedSongId: String?

    func load(for song: Song) async {
        guard loadedSongId != song.id else { return }
        loadedSongId = song.id

        // Clear first. Leaving the previous song's words on screen while the
        // new ones are fetched is what made the lyrics look like they belonged
        // to the wrong track — and if the fetch is cancelled by another change,
        // they would have stayed there indefinitely.
        lyrics = nil
        isLoading = true
        hasLoaded = false

        let found = await LyricsService.fetch(
            trackId: song.id,
            title: song.title,
            artistName: song.artistName,
            duration: song.duration
        )

        // Another track started while this was in flight — that load owns the
        // screen now.
        guard loadedSongId == song.id else { return }

        lyrics = found
        isLoading = false
        hasLoaded = true
    }

    /// Nudges highlighting ahead of the audio clock.
    ///
    /// The player reports where the *file* is, not where the sound is: what
    /// has been handed to the output has not been heard yet, and on Bluetooth
    /// that gap is large enough to read as the words trailing the vocal by a
    /// beat. iOS knows the number, so it is asked rather than guessed — a
    /// fixed 0.35 was right for the speaker and badly wrong for headphones.
    ///
    /// Smaller for timings we invented: leading an estimate compounds it.
    private var leadOffset: TimeInterval {
        if lyrics?.isApproximate ?? false { return 0.1 }

        let session = AVAudioSession.sharedInstance()
        let latency = session.outputLatency + session.ioBufferDuration
        // A floor, because some routes report zero, and a ceiling so a bad
        // reading cannot throw the whole lyric out of step.
        return min(max(latency + 0.12, 0.15), 0.6)
    }

    func activeLineIndex(at time: TimeInterval) -> Int? {
        guard let lines = lyrics?.syncedLines, !lines.isEmpty else { return nil }
        let adjusted = time + leadOffset

        // Binary search: this runs on every display frame, and walking a
        // three-hundred-line lyric each time is work the animation can feel.
        var low = 0
        var high = lines.count - 1
        var result: Int?
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].timestamp <= adjusted {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }

    /// The longest a single line is treated as being sung for.
    ///
    /// Past this the gap to the next line is a pause in the song, not a slow
    /// delivery of these words.
    private static let maxSungSeconds: TimeInterval = 8

    /// How many of a line's words have been sung, as a fractional count.
    ///
    /// Spread by *length*, not by word count. "I" and "everything" are one
    /// word each and take wildly different amounts of time to sing, so a
    /// uniform split drifts within every long line — the highlight arrives
    /// early on short words and late on long ones. Weighting by characters is
    /// crude but tracks speech closely enough that the drift stops being
    /// visible.
    func spokenWordCount(in words: [String], at time: TimeInterval) -> Double {
        guard !words.isEmpty else { return 0 }

        let progress = lineProgress(at: time)
        guard progress > 0 else { return 0 }
        guard progress < 1 else { return Double(words.count) }

        // A word costs its letters plus one for the breath after it, so a
        // short word is never free.
        let weights = words.map { Double($0.count) + 1 }
        let total = weights.reduce(0, +)
        guard total > 0 else { return progress * Double(words.count) }

        var target = progress * total
        var spoken = 0.0

        for weight in weights {
            if target >= weight {
                target -= weight
                spoken += 1
            } else {
                // Part-way through this word: carry the fraction so the fill
                // moves continuously rather than word by word.
                spoken += target / weight
                break
            }
        }

        return spoken
    }

    /// LRCLIB only provides line-level timestamps, not per-word ones. This
    /// spreads the active line evenly across the window until the next line
    /// starts, which drives a karaoke-style left-to-right fill.
    func lineProgress(at time: TimeInterval) -> Double {
        guard let lines = lyrics?.syncedLines, !lines.isEmpty,
              let index = activeLineIndex(at: time) else { return 0 }
        let line = lines[index]

        // How long the line is *sung* for, which is not the same as how long
        // it is on screen. A line before an instrumental break can be followed
        // by twenty seconds of nothing, and stretching the fill across that
        // makes the words crawl while the singer has long since stopped.
        let nextAt = lines.indices.contains(index + 1)
            ? lines[index + 1].timestamp
            : line.timestamp + 4
        let span = min(max(nextAt - line.timestamp, 0.1), Self.maxSungSeconds)

        let progress = (time + leadOffset - line.timestamp) / span
        return min(max(progress, 0), 1)
    }
}
