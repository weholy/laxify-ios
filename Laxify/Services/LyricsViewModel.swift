import Foundation

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

    /// Nudges highlighting slightly ahead of the audio clock: playback is a
    /// few frames behind the reported time once buffering and output latency
    /// are counted, which reads as the lyrics lagging the vocals.
    ///
    /// Smaller for timings we invented — those are already an estimate, and
    /// leading an estimate only compounds the error.
    private var leadOffset: TimeInterval {
        (lyrics?.isApproximate ?? false) ? 0.1 : 0.35
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

    /// LRCLIB only provides line-level timestamps, not per-word ones. This
    /// spreads the active line evenly across the window until the next line
    /// starts, which drives a karaoke-style left-to-right fill.
    func lineProgress(at time: TimeInterval) -> Double {
        guard let lines = lyrics?.syncedLines, !lines.isEmpty,
              let index = activeLineIndex(at: time) else { return 0 }
        let line = lines[index]
        let lineEnd = lines.indices.contains(index + 1) ? lines[index + 1].timestamp : line.timestamp + 4
        let span = max(lineEnd - line.timestamp, 0.1)
        let progress = (time + leadOffset - line.timestamp) / span
        return min(max(progress, 0), 1)
    }
}
