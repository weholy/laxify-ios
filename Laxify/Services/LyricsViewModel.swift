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
        if lyrics?.isApproximate ?? false { return 0.15 }

        let latency = Self.outputLatency()
        // A floor, because some routes report zero, and a ceiling so a bad
        // reading cannot throw the whole lyric out of step.
        //
        // The constant on top is deliberately a little more than the measured
        // latency alone. A highlight that arrives a breath early reads as the
        // line being announced; the same distance late reads as the app
        // lagging behind the song, which is far more noticeable. Nudged up
        // slightly (0.2→0.25) on the user's own read that the whole thing
        // still trailed a touch — kept small on purpose, this is a global
        // constant and not the fix for a single mistimed line.
        return min(max(latency + 0.25, 0.25), 0.65)
    }

    /// The route's output delay, remembered rather than read cold.
    ///
    /// This is the "lyrics keep up until I pause, then they fall behind" bug.
    /// After a pause the system lets the audio session go inactive, and an
    /// inactive session reports an output latency of zero — so on resuming,
    /// the compensation silently dropped from, say, a quarter of a second on
    /// headphones to nothing, and every line lit up late. A zero is now only
    /// believed when there has never been a real reading; otherwise the last
    /// real one stands until the route itself changes.
    ///
    /// Also: this used to be two calls into the audio session on every
    /// display frame. Once a second is plenty for a number that only changes
    /// when headphones are plugged in or taken out.
    private static var lastLatency: TimeInterval = 0
    private static var readAt: Date = .distantPast
    private static var routeObserver: NSObjectProtocol?

    private static func outputLatency() -> TimeInterval {
        if routeObserver == nil {
            routeObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
            ) { _ in
                // A different route has a different delay: let the next
                // reading replace the remembered one, zero included.
                MainActor.assumeIsolated {
                    LyricsViewModel.lastLatency = 0
                    LyricsViewModel.readAt = .distantPast
                }
            }
        }

        guard Date().timeIntervalSince(readAt) > 1 else { return lastLatency }
        readAt = Date()

        let session = AVAudioSession.sharedInstance()
        let reading = session.outputLatency + session.ioBufferDuration
        if session.outputLatency > 0 || lastLatency == 0 {
            lastLatency = reading
        }
        return lastLatency
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
    /// delivery of these words. Eight seconds was too generous: a line before
    /// an instrumental break had its fill stretched across the whole gap, so
    /// the words crawled for several seconds after the singer had finished
    /// them. Finishing the line and then waiting reads as correct; crawling
    /// reads as broken.
    private static let maxSungSeconds: TimeInterval = 5

    /// How many of a line's words have been sung, as a fractional count.
    ///
    /// The source gives one timestamp per line, never per word, so the
    /// position inside a line is worked out here. It is worked out from
    /// *syllables* rather than letters: singing time follows syllables closely
    /// and letters only loosely. "Straight" is eight letters and one syllable;
    /// "уезжаю" is six letters and three. Weighting by letters made the
    /// highlight linger on long single-syllable words and race through short
    /// many-syllable ones, which is exactly where the drift inside a line was
    /// coming from.
    func spokenWordCount(in words: [String], at time: TimeInterval) -> Double {
        guard !words.isEmpty else { return 0 }

        let progress = lineProgress(at: time)
        guard progress > 0 else { return 0 }
        guard progress < 1 else { return Double(words.count) }

        let weights = words.map(Self.syllableWeight)
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

    /// Roughly how long a word takes to sing, in syllables.
    ///
    /// A syllable is one run of vowels, in either alphabet — good enough that
    /// the count is right for almost every ordinary word, and wrong only by
    /// one on the awkward ones. The half-syllable added on top is the breath
    /// after the word, so that a line of short words does not race.
    private static func syllableWeight(_ word: String) -> Double {
        let vowels = Set("aeiouyаеёиоуыэюяAEIOUYАЕЁИОУЫЭЮЯ")

        var groups = 0
        var inVowelRun = false
        for character in word where character.isLetter {
            if vowels.contains(character) {
                if !inVowelRun { groups += 1 }
                inVowelRun = true
            } else {
                inVowelRun = false
            }
        }

        // A word with no vowels at all still takes time to say.
        return Double(max(groups, 1)) + 0.5
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
