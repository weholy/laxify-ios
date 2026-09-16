import SwiftUI
import UIKit

/// Artwork, cached and sized for where it is shown.
///
/// `AsyncImage` re-fetches and re-decodes on every appearance, which in a
/// scrolling list means the same covers are downloaded again each time they
/// come back on screen — the reason artwork felt slow. This keeps decoded
/// images in memory and the bytes on disk, so a cover is fetched once.
///
/// It also asks for a variant that matches the slot: a 500px image behind a
/// 56pt row is several times the bytes for no visible difference.
struct AsyncCoverImage: View {
    let url: URL?
    var cornerRadius: CGFloat = LaxifyMetrics.artworkCornerRadius
    /// Roughly how wide this will be drawn, in points. Picks the variant.
    var displaySize: CGFloat = 200

    @State private var image: UIImage?
    @State private var isLoading = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(LaxifyPalette.surface)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                }
                // No cover: just the flat surface — never a placeholder glyph.
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .task(id: url) {
                await load()
            }
    }

    private func load() async {
        guard let url else {
            image = nil
            return
        }

        let sized = CoverImageLoader.variant(of: url, forDisplayWidth: displaySize)

        // A cache hit is set without animating: fading in artwork that was
        // already there reads as a flicker while scrolling.
        if let cached = CoverImageLoader.shared.cached(sized) {
            image = cached
            return
        }

        image = nil
        guard let loaded = await CoverImageLoader.shared.image(for: sized) else { return }

        withAnimation(.easeOut(duration: 0.2)) {
            image = loaded
        }
    }
}

/// Shared artwork loader.
actor CoverImageLoader {
    static let shared = CoverImageLoader()

    /// Decoded images, which is the expensive half — keeping only the bytes
    /// would still cost a decode per appearance.
    ///
    /// NSCache is documented as thread-safe; Swift 6 cannot see that, so the
    /// guarantee is stated here rather than wrapped in an actor that would
    /// make the synchronous cache peek impossible.
    nonisolated(unsafe) private static let memory: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 400
        // Roughly 80 MB of decoded pixels; the system evicts under pressure.
        cache.totalCostLimit = 80 * 1024 * 1024
        return cache
    }()

    private var inFlight: [URL: Task<UIImage?, Never>] = [:]

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.urlCache = URLCache(
            memoryCapacity: 16 * 1024 * 1024,
            diskCapacity: 256 * 1024 * 1024,
            diskPath: "laxify.covers"
        )
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }()

    /// Synchronous peek, so a cached cover can be shown in the same frame.
    nonisolated func cached(_ url: URL) -> UIImage? {
        Self.memory.object(forKey: url as NSURL)
    }

    func image(for url: URL) async -> UIImage? {
        if let hit = Self.memory.object(forKey: url as NSURL) {
            return hit
        }

        // A list can ask for the same cover from several rows at once; one
        // request serves all of them.
        if let existing = inFlight[url] {
            return await existing.value
        }

        let task = Task<UIImage?, Never> { [session] in
            guard let (data, _) = try? await session.data(from: url) else { return nil }
            guard let decoded = UIImage(data: data) else { return nil }

            // Decoding here, off the main actor, keeps the first draw from
            // stuttering when the image finally appears.
            return decoded.preparingForDisplay() ?? decoded
        }

        inFlight[url] = task
        let result = await task.value
        inFlight[url] = nil

        if let result {
            let cost = Int(result.size.width * result.size.height * result.scale * result.scale * 4)
            Self.memory.setObject(result, forKey: url as NSURL, cost: cost)
        }

        return result
    }

    /// Fetches artwork before anything asks to draw it.
    ///
    /// A feed arrives as a list of urls a moment before its rows appear.
    /// Starting those fetches then, rather than when each row scrolls into
    /// place, is the difference between covers that are already there and
    /// covers that fade in one by one.
    nonisolated static func prefetch(_ urls: [URL?], displayWidth: CGFloat = 200) {
        let wanted = urls
            .compactMap { $0 }
            .map { variant(of: $0, forDisplayWidth: displayWidth) }
            .filter { shared.cached($0) == nil }

        guard !wanted.isEmpty else { return }

        Task.detached(priority: .utility) {
            // Sequential on purpose: these are background fetches, and firing
            // thirty at once would compete with whatever the listener is
            // actually waiting for.
            for url in wanted.prefix(40) {
                _ = await shared.image(for: url)
            }
        }
    }

    /// Rewrites an artwork url to the smallest variant that still looks sharp.
    ///
    /// The source publishes several sizes under a predictable suffix. Asking
    /// for the one that matches the slot is the single biggest thing that
    /// makes a grid of covers appear quickly.
    /// This used to know about one host, and by then the catalogue was coming
    /// from several. A cover from the metadata provider arrived as a 640px
    /// square, went through here untouched, and was drawn into a 56pt row —
    /// something like thirty times the bytes for a picture the size of a
    /// thumbnail, on every row of every list. That, not the network, is why a
    /// long list of tracks filled in slowly and unevenly.
    nonisolated static func variant(of url: URL, forDisplayWidth width: CGFloat) -> URL {
        let text = url.absoluteString
        let pixels = width * UIScreen.main.scale

        if text.contains("sndcdn.com") { return rewriteSoundCloud(text, pixels) ?? url }
        if text.contains("i.scdn.co") { return rewriteSpotify(text, pixels) ?? url }
        if text.contains("avatars.yandex.net") { return rewriteYandex(text, pixels) ?? url }
        if text.contains("ytimg.com") || text.contains("googleusercontent.com") {
            return rewriteGoogle(text, pixels) ?? url
        }

        return url
    }

    private nonisolated static func rewriteSoundCloud(_ text: String, _ pixels: CGFloat) -> URL? {
        let suffix: String = switch pixels {
        case ..<130: "-t120x120"
        case ..<220: "-t200x200"
        case ..<320: "-t300x300"
        case ..<520: "-t500x500"
        default: "-original"
        }

        // Every known variant is swapped for the chosen one, so this works
        // whichever size the server happened to hand out.
        var rewritten = text
        for known in ["-t500x500", "-t300x300", "-t200x200", "-t120x120", "-large", "-original"] {
            if rewritten.contains(known) {
                rewritten = rewritten.replacingOccurrences(of: known, with: suffix)
                break
            }
        }

        return URL(string: rewritten)
    }

    /// The metadata provider encodes the size inside the image id itself, in
    /// a fixed token that differs between release art and artist portraits.
    /// Both families are handled; anything else is left alone rather than
    /// mangled into a url that returns nothing.
    private nonisolated static func rewriteSpotify(_ text: String, _ pixels: CGFloat) -> URL? {
        /// Largest first, so the search below finds whichever one is present.
        let releaseArt = ["0000b273": 640.0, "00001e02": 300.0, "00004851": 64.0]
        let portraits = ["0000e5eb": 640.0, "00005174": 320.0, "0000f178": 160.0]

        for family in [releaseArt, portraits] {
            guard let present = family.keys.first(where: { text.contains($0) }) else { continue }

            // The smallest variant that is still at least as wide as the slot;
            // the largest when nothing is.
            let wanted = family
                .filter { $0.value >= pixels }
                .min { $0.value < $1.value }?.key
                ?? family.max { $0.value < $1.value }?.key

            guard let wanted else { return URL(string: text) }
            return URL(string: text.replacingOccurrences(of: present, with: wanted))
        }

        return URL(string: text)
    }

    /// Sizes here are written into the path as `NxN`, and the service will
    /// serve whichever is asked for.
    private nonisolated static func rewriteYandex(_ text: String, _ pixels: CGFloat) -> URL? {
        let side: Int = switch pixels {
        case ..<110: 100
        case ..<220: 200
        case ..<420: 400
        default: 1000
        }

        // The size is the last path component, written as `NxN`. Read as a
        // path component rather than searched for as a pattern, so an id that
        // happens to contain digits and an "x" cannot be rewritten by
        // accident.
        var parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard let last = parts.last else { return URL(string: text) }

        let halves = last.split(separator: "x")
        guard halves.count == 2,
              halves.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) })
        else { return URL(string: text) }

        parts[parts.count - 1] = Substring("\(side)x\(side)")
        return URL(string: parts.joined(separator: "/"))
    }

    /// Two shapes: a sized suffix that can simply be rewritten, and a set of
    /// fixed names to pick between.
    private nonisolated static func rewriteGoogle(_ text: String, _ pixels: CGFloat) -> URL? {
        let side: Int = switch pixels {
        case ..<130: 120
        case ..<240: 226
        case ..<420: 400
        default: 544
        }

        // `...=w544-h544-l90-rj`: everything up to the marker is the image,
        // everything after it is a list of options, and the first two are the
        // size. Rebuilt by hand rather than by pattern, because a regex
        // literal starting `=w` is ambiguous with an operator.
        if let marker = text.range(of: "=w") {
            let head = text[..<marker.lowerBound]
            let options = text[marker.upperBound...].split(separator: "-").dropFirst(2)
            let rest = options.isEmpty ? "" : "-" + options.joined(separator: "-")
            return URL(string: "\(head)=w\(side)-h\(side)\(rest)")
        }

        let name: String = switch pixels {
        case ..<130: "default"
        case ..<340: "mqdefault"
        case ..<500: "hqdefault"
        default: "maxresdefault"
        }

        var rewritten = text
        for known in ["maxresdefault", "sddefault", "hqdefault", "mqdefault", "default"] {
            if rewritten.contains(known) {
                rewritten = rewritten.replacingOccurrences(of: known, with: name)
                break
            }
        }

        return URL(string: rewritten)
    }
}

extension AsyncCoverImage {
    /// Convenience for the common case: a list of tracks about to be shown.
    static func prefetchCovers(for songs: [Song], width: CGFloat = 200) {
        CoverImageLoader.prefetch(songs.map(\.coverURL), displayWidth: width)
    }
}
