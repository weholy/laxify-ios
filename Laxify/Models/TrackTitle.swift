import Foundation

/// Turning an upload's file name into a track's name.
///
/// A catalog built on uploads gives titles the way people type them into an
/// upload form: `Lil Peep - Star Shopping (Official Video) [FREE DOWNLOAD]`.
/// Streaming services show two fields instead — "Star Shopping" by "Lil Peep"
/// — and every screen in this app that lists a track, statistics most of all,
/// reads better for the same treatment.
///
/// Conservative by design. A parenthesis is only dropped when it holds a word
/// from the noise list and none from the keep list, because `(feat. Juice
/// WRLD)`, `(Slowed + Reverb)` and `(Radio Edit)` are part of the title and
/// throwing them away would be a worse error than leaving `(HD)` behind.
enum TrackTitle {

    /// Words that mean the group is packaging, not title.
    private static let noise: [String] = [
        "official video", "official music video", "official audio",
        "official visualizer", "official lyric video", "official",
        "music video", "lyric video", "lyrics", "lyric", "visualizer",
        "free download", "free dl", "download now", "out now",
        "hd", "hq", "4k", "1080p", "explicit",
        "премьера", "клип", "официальный"
    ]

    /// Words that make the group part of the name, whatever else it holds.
    private static let keep: [String] = [
        "feat", "ft.", "ft ", "with ", "remix", "prod", "version", "live",
        "acoustic", "cover", "edit", "mix", "remaster", "instrumental",
        "slowed", "sped", "reverb", "bootleg", "vip", "demo", "part", "pt."
    ]

    private static let separators = [" - ", " – ", " — ", " ‒ "]

    /// The cleaned title, and the artist it belongs to.
    ///
    /// - Parameter artistIsCredited: whether `artist` came from the release's
    ///   own credit rather than from whoever uploaded it. An uploader is
    ///   called `☆LiL PEEP☆`; when that is all there is and the title says
    ///   `Lil Peep - Star Shopping`, the title is the better source.
    static func clean(
        title raw: String,
        artist: String?,
        artistIsCredited: Bool
    ) -> (title: String, artist: String?) {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var resolved = artist

        if let split = splitLeadingArtist(from: title) {
            if let artist, artist.compare(split.artist, options: .caseInsensitive) == .orderedSame {
                // The title repeats the artist. Drop the repetition.
                title = split.title
            } else if !artistIsCredited {
                // Nothing credited the release, so the title is the only
                // place the real name appears.
                resolved = split.artist
                title = split.title
            }
        }

        title = stripPackaging(from: title)
        title = tidy(title)

        return (title.isEmpty ? raw : title, resolved)
    }

    /// Title-only cleaning, for rows read back from history where the artist
    /// was already recorded separately.
    static func clean(_ raw: String) -> String {
        let stripped = tidy(stripPackaging(from: raw.trimmingCharacters(in: .whitespacesAndNewlines)))
        return stripped.isEmpty ? raw : stripped
    }

    /// A credit line — "MORGENSHTERN, ELDZHEY", "Lil Peep & Lil Tracy",
    /// "Skrillex feat. Sirah" — split into the individual names in it, in
    /// credited order.
    ///
    /// The source only ever gives one id alongside this string (the
    /// uploader's), so this by itself does not say which of several names
    /// it belongs to — see the call site in `SoundCloudDirect.song`, which
    /// matches by username and falls back to the first name rather than
    /// guessing wrong.
    static func splitCredited(_ name: String) -> [String] {
        var working = name
        for phrase in [" feat. ", " feat ", " ft. ", " ft ", " vs. ", " vs ", " and ", " x ", " & "] {
            working = working.replacingOccurrences(of: phrase, with: ",", options: .caseInsensitive)
        }
        return working
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Pieces

    private static func splitLeadingArtist(from title: String) -> (artist: String, title: String)? {
        for separator in separators {
            guard let range = title.range(of: separator) else { continue }

            let left = String(title[title.startIndex..<range.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            let right = String(title[range.upperBound...])
                .trimmingCharacters(in: .whitespaces)

            // A long left side is part of the name, not a credit; an empty
            // right side means the separator was decoration.
            guard !left.isEmpty, !right.isEmpty, left.count <= 45 else { continue }

            return (left, right)
        }
        return nil
    }

    /// Removes bracketed groups that are packaging, and a trailing `| …` tail
    /// when that is packaging too.
    private static func stripPackaging(from title: String) -> String {
        var result = ""
        var group = ""
        var depth = 0
        var opener: Character = "("

        for character in title {
            switch character {
            case "(", "[":
                if depth == 0 {
                    opener = character
                    group = ""
                } else {
                    group.append(character)
                }
                depth += 1

            case ")", "]":
                if depth > 0 {
                    depth -= 1
                    if depth == 0 {
                        if !isPackaging(group) {
                            result.append(opener)
                            result.append(group)
                            result.append(opener == "(" ? ")" : "]")
                        }
                    } else {
                        group.append(character)
                    }
                }

            default:
                if depth > 0 {
                    group.append(character)
                } else {
                    result.append(character)
                }
            }
        }

        // An unbalanced opener: keep what was collected rather than lose it.
        if depth > 0 {
            result.append(opener)
            result.append(group)
        }

        if let bar = result.firstIndex(of: "|") {
            let tail = String(result[result.index(after: bar)...])
            if isPackaging(tail) {
                result = String(result[result.startIndex..<bar])
            }
        }

        return result
    }

    private static func isPackaging(_ group: String) -> Bool {
        let lowered = group.lowercased().trimmingCharacters(in: .whitespaces)
        guard !lowered.isEmpty else { return true }
        guard !keep.contains(where: { lowered.contains($0) }) else { return false }
        return noise.contains { lowered.contains($0) }
    }

    private static func tidy(_ title: String) -> String {
        title
            .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " -–—|·•_,"))
    }
}
