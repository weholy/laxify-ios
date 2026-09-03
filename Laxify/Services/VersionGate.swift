import Foundation

/// Whether this build is still allowed in.
///
/// Checked once per launch, against a value an operator sets from Випка —
/// nothing here needs a redeploy. Fails open: a server that cannot be
/// reached, or a floor that will not parse, means nobody is blocked. The
/// point of this gate is to retire an old build deliberately, not to take
/// the app down the next time the network hiccups.
@MainActor
@Observable
final class VersionGate {
    static let shared = VersionGate()

    private(set) var isBlocked = false

    private init() {}

    func check() async {
        guard let config = try? await LaxifyAPI.shared.appConfig() else { return }
        isBlocked = AppVersion.isOlder(than: config.minSupportedVersion)
    }
}
