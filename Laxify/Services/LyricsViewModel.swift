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
}
