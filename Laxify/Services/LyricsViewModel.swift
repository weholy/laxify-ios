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

    func activeLineIndex(at time: TimeInterval) -> Int? {
        guard let lines = lyrics?.syncedLines, !lines.isEmpty else { return nil }
        var result: Int?
        for (index, line) in lines.enumerated() {
            if line.timestamp <= time {
                result = index
            } else {
                break
            }
        }
        return result
    }

    /// LRCLIB only provides line-level timestamps, not per-word ones. This
    /// approximates a karaoke-style word reveal by spreading the active
    /// line's words evenly across the window until the next line starts.
    func wordRevealProgress(at time: TimeInterval) -> Double {
        guard let lines = lyrics?.syncedLines, !lines.isEmpty,
              let index = activeLineIndex(at: time) else { return 0 }
        let line = lines[index]
        let lineEnd = lines.indices.contains(index + 1) ? lines[index + 1].timestamp : line.timestamp + 4
        let span = max(lineEnd - line.timestamp, 0.1)
        let progress = (time - line.timestamp) / span
        return min(max(progress, 0), 1)
    }
}
