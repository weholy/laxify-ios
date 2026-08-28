import SwiftUI
import UIKit

/// Locally-set playlist covers, keyed by playlist id. Kept on the device for
/// now — pushing them so other viewers see the cover is a backend step.
@MainActor
@Observable
final class PlaylistCoverStore {
    static let shared = PlaylistCoverStore()

    private var cache: [String: UIImage] = [:]
    private let dir: URL
    /// Bumped on every change so views observing the store refresh.
    private(set) var version = 0

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("playlist-covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func image(for id: String) -> UIImage? {
        _ = version // read so callers observe changes
        if let cached = cache[id] { return cached }
        guard let image = UIImage(contentsOfFile: url(for: id).path) else { return nil }
        cache[id] = image
        return image
    }

    func set(_ data: Data, for id: String) {
        guard let picked = UIImage(data: data) else { return }
        let resized = Self.resized(picked, maxDimension: 900)
        if let jpeg = resized.jpegData(compressionQuality: 0.82) {
            try? jpeg.write(to: url(for: id), options: .atomic)
        }
        cache[id] = resized
        withAnimation(.easeInOut(duration: 0.25)) { version += 1 }
    }

    func clear(for id: String) {
        try? FileManager.default.removeItem(at: url(for: id))
        cache[id] = nil
        withAnimation(.easeInOut(duration: 0.25)) { version += 1 }
    }

    private func url(for id: String) -> URL {
        dir.appendingPathComponent("\(id).jpg")
    }

    private static func resized(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension else { return image }
        let scale = maxDimension / longest
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
