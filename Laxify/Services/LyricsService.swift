import Foundation

struct LyricLine: Identifiable, Sendable {
    let id = UUID()
    let timestamp: TimeInterval
    let text: String
}

struct Lyrics: Sendable {
    let syncedLines: [LyricLine]
    let plainText: String?

    var isSynced: Bool { !syncedLines.isEmpty }
}

enum LyricsService {
    static func fetch(title: String, artistName: String, duration: TimeInterval) async -> Lyrics? {
        var components = URLComponents(string: "https://lrclib.net/api/get")
        components?.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artistName),
            URLQueryItem(name: "duration", value: String(Int(duration.rounded())))
        ]

        guard let url = components?.url else { return nil }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(LRCLIBResponse.self, from: data)
            let syncedLines = response.syncedLyrics.map(parse) ?? []
            return Lyrics(syncedLines: syncedLines, plainText: response.plainLyrics)
        } catch {
            return nil
        }
    }

    private static func parse(_ raw: String) -> [LyricLine] {
        raw.split(separator: "\n").compactMap { line -> LyricLine? in
            guard line.hasPrefix("["), let closeBracket = line.firstIndex(of: "]") else { return nil }

            let timeString = line[line.index(after: line.startIndex)..<closeBracket]
            let text = String(line[line.index(after: closeBracket)...]).trimmingCharacters(in: .whitespaces)

            let parts = timeString.split(separator: ":")
            guard parts.count == 2,
                  let minutes = Double(parts[0]),
                  let seconds = Double(parts[1]) else { return nil }

            return LyricLine(timestamp: minutes * 60 + seconds, text: text)
        }
    }
}

private struct LRCLIBResponse: Decodable {
    let plainLyrics: String?
    let syncedLyrics: String?
}
