import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    // Russian and English only — the machine-translated ES/ZH passes were
    // pulled until a native review.
    case en, ru

    var id: String { rawValue }

    var nativeName: String {
        switch self {
        case .en: "English"
        case .ru: "Русский"
        }
    }

    var englishName: String {
        switch self {
        case .en: "English"
        case .ru: "Russian"
        }
    }

    var flag: String {
        switch self {
        case .en: "🇬🇧"
        case .ru: "🇷🇺"
        }
    }

    static var deviceDefault: AppLanguage {
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        return AppLanguage(rawValue: code) ?? .en
    }
}

/// The chosen interface language, applied without a relaunch.
///
/// Strings live in a Swift table rather than `.strings` files: every lookup
/// goes through `LocalizationManager.shared`, so a view that reads a string
/// during `body` is subscribed to the manager and re-renders the moment the
/// language changes — which `Bundle.main`-based localization cannot do.
@MainActor
@Observable
final class LocalizationManager {
    static let shared = LocalizationManager()

    private static let languageKey = "laxify.language"
    private static let pickedKey = "laxify.language.picked"

    private(set) var language: AppLanguage
    private(set) var hasPicked: Bool

    private init() {
        hasPicked = UserDefaults.standard.bool(forKey: Self.pickedKey)
        if let raw = UserDefaults.standard.string(forKey: Self.languageKey),
           let stored = AppLanguage(rawValue: raw) {
            language = stored
        } else {
            language = AppLanguage.deviceDefault
        }
    }

    func choose(_ language: AppLanguage) {
        self.language = language
        hasPicked = true
        UserDefaults.standard.set(language.rawValue, forKey: Self.languageKey)
        UserDefaults.standard.set(true, forKey: Self.pickedKey)
    }

    func string(_ key: String, _ fallback: String) -> String {
        Translations.table[language]?[key]
            ?? Translations.table[.en]?[key]
            ?? fallback
    }
}

/// Shorthand for a localized string. Reads the manager, so any SwiftUI view
/// that calls this in its body follows language changes automatically.
@MainActor
func L(_ key: String, _ fallback: String) -> String {
    LocalizationManager.shared.string(key, fallback)
}
