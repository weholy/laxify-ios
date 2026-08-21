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
        isLoading = true
        hasLoaded = false
        lyrics = await LyricsService.fetch(title: song.title, artistName: song.artistName, duration: song.duration)
        isLoading = false
        hasLoaded = true
    }

    /// Nudges highlighting slightly ahead of the audio clock: playback is a
    /// few frames behind the reported time once buffering and output latency
    /// are counted, which reads as the lyrics lagging the vocals.
    private let leadOffset: TimeInterval = 0.35

    func activeLineIndex(at time: TimeInterval) -> Int? {
        guard let lines = lyrics?.syncedLines, !lines.isEmpty else { return nil }
        let adjusted = time + leadOffset
        var result: Int?
        for (index, line) in lines.enumerated() {
            if line.timestamp <= adjusted {
                result = index
            } else {
                break
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
