import SwiftUI

/// How the app looks on this device.
///
/// Deliberately local rather than on the account: someone using a dark phone
/// and a light iPad wants each to follow that device, not the last one they
/// changed.
@MainActor
@Observable
final class AppearanceSettings {
    static let shared = AppearanceSettings()

    enum Theme: String, CaseIterable, Sendable {
        case system
        case light
        case dark

        var title: String {
            switch self {
            case .system: "Как в системе"
            case .light: "Светлая"
            case .dark: "Тёмная"
            }
        }

        /// One line saying what picking this actually does.
        var explanation: String {
            switch self {
            case .system: "Меняется вместе с телефоном"
            case .light: "Всегда светлое оформление"
            case .dark: "Всегда тёмное оформление"
            }
        }

        var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    var theme: Theme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: Self.themeKey) }
    }

    private static let themeKey = "laxify.appearance.theme"

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.themeKey)
        theme = stored.flatMap(Theme.init(rawValue:)) ?? .system
    }
}
