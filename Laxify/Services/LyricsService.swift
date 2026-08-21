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
    /// Tries progressively looser lookups: an exact duration-matched hit is
    /// best, but lesser-known tracks are often only indexed under a slightly
    /// different title/artist spelling, or with no duration at all, so fall
    /// back to search before giving up.
    static func fetch(title: String, artistName: String, duration: TimeInterval) async -> Lyrics? {
        let cleanTitle = normalized(title)
        let primaryArtist = artistName
            .split(separator: ",")
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? artistName

        if let exact = await get(title: title, artist: artistName, duration: duration) {
            return exact
        }
        if cleanTitle != title || primaryArtist != artistName,
           let cleaned = await get(title: cleanTitle, artist: primaryArtist, duration: duration) {
            return cleaned
        }
        if let noDuration = await get(title: cleanTitle, artist: primaryArtist, duration: nil) {
            return noDuration
        }
        if let searched = await search(title: cleanTitle, artist: primaryArtist, duration: duration) {
            return searched
        }
        return await search(title: cleanTitle, artist: nil, duration: duration)
    }

    /// Strips the bracketed noise labels ("(feat. X)", "[Remix]", "prod. by …")
    /// that keep an otherwise-indexed track from matching.
    private static func normalized(_ title: String) -> String {
        var result = title
        for pattern in ["\\([^)]*\\)", "\\[[^\\]]*\\]", "(?i)\\s*(feat\\.|ft\\.|prod\\.).*$"] {
            result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func get(title: String, artist: String, duration: TimeInterval?) async -> Lyrics? {
        var components = URLComponents(string: "https://lrclib.net/api/get")
        var items = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist)
        ]
        if let duration {
            items.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded()))))
        }
        components?.queryItems = items

        guard let url = components?.url else { return nil }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(LRCLIBResponse.self, from: data)
            return lyrics(from: response)
        } catch {
            return nil
        }
    }

    private static func search(title: String, artist: String?, duration: TimeInterval) async -> Lyrics? {
        var components = URLComponents(string: "https://lrclib.net/api/search")
        var items = [URLQueryItem(name: "track_name", value: title)]
        if let artist {
            items.append(URLQueryItem(name: "artist_name", value: artist))
        }
        components?.queryItems = items

        guard let url = components?.url else { return nil }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let results = try JSONDecoder().decode([LRCLIBResponse].self, from: data)
            guard !results.isEmpty else { return nil }

            let synced = results.filter { $0.syncedLyrics?.isEmpty == false }
            let pool = synced.isEmpty ? results : synced
            let best = pool.min { left, right in
                abs((left.duration ?? 0) - duration) < abs((right.duration ?? 0) - duration)
            }
            return best.flatMap(lyrics(from:))
        } catch {
            return nil
        }
    }

    private static func lyrics(from response: LRCLIBResponse) -> Lyrics? {
        let syncedLines = response.syncedLyrics.map(parse) ?? []
        let plain = response.plainLyrics
        guard !syncedLines.isEmpty || !(plain ?? "").isEmpty else { return nil }
        return Lyrics(syncedLines: syncedLines, plainText: plain)
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
        .sorted { $0.timestamp < $1.timestamp }
    }
}

private struct LRCLIBResponse: Decodable {
    let plainLyrics: String?
    let syncedLyrics: String?
    let duration: Double?
}
