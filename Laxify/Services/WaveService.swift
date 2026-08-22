import Foundation
@preconcurrency import YMAPI

/// The real personal radio, not a home-made ranking.
///
/// The source has a dedicated station engine ("rotor") that already picks by
/// genre, mood, tempo and a lot of signals we cannot see — and, critically,
/// it learns from playback feedback. Our earlier approach only reshuffled
/// tracks by favourited artist, which could never surface anything new.
/// Here we drive that station directly and report back what was played,
/// finished or skipped, so it keeps adapting.
enum WaveStation {
    /// The personal station every account has.
    static let personal = "user:onyourwave"
}

struct WaveSettings: Sendable, Equatable {
    enum Mood: String, CaseIterable, Sendable {
        case all
        case fun
        case active
        case calm
        case sad

        var title: String {
            switch self {
            case .all: "Любое"
            case .fun: "Бодрое"
            case .active: "Энергичное"
            case .calm: "Спокойное"
            case .sad: "Грустное"
            }
        }
    }

    enum Diversity: String, CaseIterable, Sendable {
        case `default`
        case favorite
        case popular
        case discover

        var title: String {
            switch self {
            case .default: "По умолчанию"
            case .favorite: "Любимое"
            case .popular: "Популярное"
            case .discover: "Незнакомое"
            }
        }
    }

    enum Language: String, CaseIterable, Sendable {
        case any
        case russian
        case notRussian

        var title: String {
            switch self {
            case .any: "Любой"
            case .russian: "Русский"
            case .notRussian: "Иностранный"
            }
        }
    }

    var mood: Mood = .all
    var diversity: Diversity = .default
    var language: Language = .any

    static let storageKey = "laxify.wave.settings"

    static func load() -> WaveSettings {
        let defaults = UserDefaults.standard
        guard let raw = defaults.dictionary(forKey: storageKey) as? [String: String] else {
            return WaveSettings()
        }
        return WaveSettings(
            mood: Mood(rawValue: raw["mood"] ?? "") ?? .all,
            diversity: Diversity(rawValue: raw["diversity"] ?? "") ?? .default,
            language: Language(rawValue: raw["language"] ?? "") ?? .any
        )
    }

    func save() {
        UserDefaults.standard.set(
            ["mood": mood.rawValue, "diversity": diversity.rawValue, "language": language.rawValue],
            forKey: Self.storageKey
        )
    }
}

struct WaveBatch: Sendable {
    let songs: [Song]
    let batchId: String
}
