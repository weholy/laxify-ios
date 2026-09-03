import UIKit

/// Asks iOS not to suspend us for the next few seconds.
///
/// Starting a track is a network round trip followed by an `AVPlayer` warming
/// up, and none of it counts as "playing audio" yet. Leave the app in that
/// window and the system suspends the process, the fetch dies, and the track
/// never starts — which is why pressing play and immediately switching apps
/// produced silence while waiting for the first note did not.
///
/// Scoped rather than global: taken when the work starts, released the moment
/// it finishes, and released by the expiry handler if the work outlives its
/// grant, because an assertion that is never ended is a crash.
@MainActor
final class BackgroundAssertion {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(_ name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            // Expired. iOS kills the process if this is not ended here.
            self?.end()
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }

    deinit {
        let identifier = identifier
        guard identifier != .invalid else { return }
        Task { @MainActor in UIApplication.shared.endBackgroundTask(identifier) }
    }
}
