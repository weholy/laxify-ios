import SwiftUI

/// The interface choices that are still worth offering.
///
/// Applied live. The old version of this snapshotted its value at launch and
/// needed a plaque asking for a relaunch; the tab bar now reads the switch on
/// every render, so flipping it shows the result under your finger.
@MainActor
@Observable
final class InterfaceSettings {
    static let shared = InterfaceSettings()

    private static let hideLabelsKey = "laxify.tabbar.hideLabels"

    /// Whether the bottom bar is glyphs only.
    var hideTabLabels: Bool {
        didSet { UserDefaults.standard.set(hideTabLabels, forKey: Self.hideLabelsKey) }
    }

    private init() {
        // Icons only is where the app landed, so that is what someone who
        // never touches the switch gets. `object(forKey:)` rather than
        // `bool(forKey:)` — the latter cannot tell "off" from "never set".
        hideTabLabels = UserDefaults.standard.object(forKey: Self.hideLabelsKey) as? Bool ?? true
    }
}
