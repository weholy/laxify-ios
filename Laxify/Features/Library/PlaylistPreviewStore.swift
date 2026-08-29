import SwiftUI

/// The last few track covers of each playlist, so a playlist with no picked
/// cover shows a collage of its music instead of a placeholder glyph.
///
/// The list endpoint doesn't carry track art, so the detail is fetched once
/// per playlist, lazily, and the cover URLs are cached to disk.
@Observable
@MainActor
final class PlaylistPreviewStore {
    static let shared = PlaylistPreviewStore()

    /// playlist id -> up to four cover URLs, newest first.
    private(set) var covers: [String: [URL]] = [:]
    private var inFlight: Set<String> = []

    private static let cacheURL: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("playlist-previews.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: Self.cacheURL),
           let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) {
            covers = decoded.mapValues { $0.compactMap(URL.init(string:)) }
        }
    }

    /// Cover URLs for a playlist, fetching them in the background on first ask.
    func previews(for playlist: PlaylistDTO) -> [URL] {
        if let cached = covers[playlist.id] { return cached }
        guard playlist.trackCount > 0 else { return [] }
        fetch(playlist.id)
        return []
    }

    /// Call after a playlist's tracks change so the collage refreshes.
    func invalidate(_ playlistId: String) {
        covers[playlistId] = nil
        fetch(playlistId)
    }

    private func fetch(_ id: String) {
        guard !inFlight.contains(id) else { return }
        inFlight.insert(id)
        Task { [weak self] in
            defer { self?.inFlight.remove(id) }
            guard let detail = try? await LaxifyAPI.shared.playlist(id: id) else { return }
            let urls = detail.songs.compactMap(\.coverURL)
            var seen = Set<URL>()
            let unique = urls.filter { seen.insert($0).inserted }
            let top = Array(unique.prefix(4))
            self?.covers[id] = top
            self?.persist()
        }
    }

    private func persist() {
        let plain = covers.mapValues { $0.map(\.absoluteString) }
        if let data = try? JSONEncoder().encode(plain) {
            try? data.write(to: Self.cacheURL, options: .atomic)
        }
    }
}

/// A 2×2 (or 1-up) grid of cover art, clipped to `shape`. Falls back to
/// `placeholder` when there is nothing to show.
struct CoverCollage<Placeholder: View>: View {
    let urls: [URL]
    var displaySize: CGFloat = 120
    @ViewBuilder var placeholder: () -> Placeholder

    var body: some View {
        GeometryReader { geo in
            let side = geo.size.width
            if urls.isEmpty {
                placeholder()
            } else if urls.count < 4 {
                AsyncCoverImage(url: urls[0], cornerRadius: 0, displaySize: displaySize)
                    .frame(width: side, height: side)
            } else {
                let half = side / 2
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        tile(urls[0], half)
                        tile(urls[1], half)
                    }
                    HStack(spacing: 0) {
                        tile(urls[2], half)
                        tile(urls[3], half)
                    }
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func tile(_ url: URL, _ side: CGFloat) -> some View {
        AsyncCoverImage(url: url, cornerRadius: 0, displaySize: displaySize / 2)
            .frame(width: side, height: side)
            .clipped()
    }
}
