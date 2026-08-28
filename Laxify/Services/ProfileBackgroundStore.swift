import SwiftUI
import UIKit

/// The custom image behind the profile header, chosen by the owner.
///
/// Local for now — the file sits in Application Support and the profile reads
/// it straight off disk. Uploading it so other viewers see it is a later,
/// backend-side step.
@MainActor
@Observable
final class ProfileBackgroundStore {
    static let shared = ProfileBackgroundStore()

    private(set) var image: UIImage?

    private let fileURL: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("profile-background.jpg")
        image = UIImage(contentsOfFile: fileURL.path)
    }

    func set(_ data: Data) {
        guard let picked = UIImage(data: data) else { return }
        // Downscale so a huge photo does not sit in memory or on disk.
        let resized = Self.resized(picked, maxDimension: 1400)
        if let jpeg = resized.jpegData(compressionQuality: 0.82) {
            try? jpeg.write(to: fileURL, options: .atomic)
        }
        withAnimation(.easeInOut(duration: 0.3)) { image = resized }
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        withAnimation(.easeInOut(duration: 0.3)) { image = nil }
    }

    private static func resized(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension else { return image }
        let scale = maxDimension / longest
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }
}
