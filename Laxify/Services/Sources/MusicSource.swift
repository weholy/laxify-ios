import Foundation

/// Where the music comes from.
///
/// The app was built around one source and reached for it by name from three
/// dozen places. Adding a second could not be a matter of swapping that name:
/// a track id means nothing without knowing whose id it is, and everything
/// the app keeps — favourites, listening history, downloads, the tracks it
/// has learned will not play — is filed by that id. Two sources numbering
/// their tracks from one would have quietly merged into each other.
///
/// So an id carries its source. `sc:12345` and `ya:12345` are different
/// tracks, file separately, download separately and count separately, and
/// nothing above this line has to think about it.
enum MusicSource: String, CaseIterable, Identifiable, Codable, Sendable {
    case yandex = "ya"
    case soundcloud = "sc"
    case ytmusic = "yt"

    var id: String { rawValue }

    /// Shown under the logo. Deliberately the plain names people use.
    var title: String {
        switch self {
        case .yandex: "Яндекс Музыка"
        case .soundcloud: "SoundCloud"
        case .ytmusic: "YouTube Music"
        }
    }

    /// The order they appear in the switcher.
    static let ordered: [MusicSource] = [.yandex, .soundcloud, .ytmusic]
}

// MARK: - Ids

extension MusicSource {
    /// Files one of this source's own ids under it.
    func namespaced(_ rawId: String) -> String {
        guard !rawId.isEmpty else { return rawId }
        // Already carries a source — most often because it came back out of
        // something this app stored earlier.
        if Self.prefix(of: rawId) != nil { return rawId }
        return "\(rawValue):\(rawId)"
    }

    /// Which source a track id belongs to.
    ///
    /// A bare id means the one source that existed before any of this, so
    /// every favourite, play and download saved by an earlier version keeps
    /// working exactly as it did.
    static func of(_ trackId: String) -> MusicSource {
        prefix(of: trackId) ?? .soundcloud
    }

    /// The id as its own source knows it.
    static func rawId(_ trackId: String) -> String {
        guard prefix(of: trackId) != nil,
              let colon = trackId.firstIndex(of: ":")
        else {
            // Includes `sp:…`, the metadata provider's own id for a track
            // whose audio is found on SoundCloud. That prefix belongs to the
            // id rather than naming a source, so it is passed through whole.
            return trackId
        }
        return String(trackId[trackId.index(after: colon)...])
    }

    private static func prefix(of trackId: String) -> MusicSource? {
        guard let colon = trackId.firstIndex(of: ":") else { return nil }
        return MusicSource(rawValue: String(trackId[..<colon]))
    }
}

// MARK: - What is selected right now

/// The chosen source, readable from anywhere.
///
/// The screens read it through `SourceStore`, which is observable and lives
/// on the main actor. Services need the same answer from whatever thread they
/// happen to be on, and cannot wait on the main actor to get it — so the
/// value itself lives here behind a lock, and the observable object mirrors
/// it for SwiftUI.
enum SelectedSource {
    private static let key = "laxify.source.selected"
    private static let lock = NSLock()

    nonisolated(unsafe) private static var value: MusicSource = {
        let stored = UserDefaults.standard.string(forKey: key) ?? ""
        return MusicSource(rawValue: stored) ?? .soundcloud
    }()

    static var current: MusicSource {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    static func set(_ source: MusicSource) {
        lock.lock()
        value = source
        lock.unlock()

        UserDefaults.standard.set(source.rawValue, forKey: key)
    }
}
