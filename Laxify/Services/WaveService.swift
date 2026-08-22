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

extension YandexMusicService {
    /// Fetches the next run of station tracks.
    ///
    /// `lastTrackId` matters: passing the track the listener just heard is how
    /// the station continues the same session instead of restarting it.
    func waveBatch(lastTrackId: String? = nil) async throws -> WaveBatch {
        try await ensureReady()

        let result = try await run { completion in
            YMClient.shared.getRadioStationTracksBatch(
                stationId: WaveStation.personal,
                settings2: true,
                lastTrackId: lastTrackId,
                completion: completion
            )
        }

        let songs = result.sequence.compactMap(\.track).map(song(from:))
        guard !songs.isEmpty else {
            throw MusicServiceError.notFound
        }
        return WaveBatch(songs: songs, batchId: result.batchId)
    }

    func startWaveSession() async {
        guard (try? await ensureReady()) != nil else { return }
        _ = try? await run { completion in
            YMClient.shared.sendRadioStationStartListening(
                stationId: WaveStation.personal,
                fromInfo: "laxify",
                completion: completion
            )
        }
    }

    /// Feedback is what makes the station personal — without it the same
    /// generic selection comes back every time.
    func reportWaveTrackStarted(trackId: String, batchId: String) async {
        guard (try? await ensureReady()) != nil else { return }
        _ = try? await run { completion in
            YMClient.shared.sendRadioTrackStartListening(
                stationId: WaveStation.personal,
                tracksBatchId: batchId,
                trackId: trackId,
                completion: completion
            )
        }
    }

    func reportWaveTrackFinished(trackId: String, batchId: String, playedSeconds: Double) async {
        guard (try? await ensureReady()) != nil else { return }
        _ = try? await run { completion in
            YMClient.shared.sendRadioTrackFinished(
                stationId: WaveStation.personal,
                tracksBatchId: batchId,
                trackId: trackId,
                playedDurationInS: playedSeconds,
                completion: completion
            )
        }
    }

    func reportWaveTrackSkipped(trackId: String, playedSeconds: Double) async {
        guard (try? await ensureReady()) != nil else { return }
        _ = try? await run { completion in
            YMClient.shared.sendRadioTrackSkip(
                stationId: WaveStation.personal,
                trackId: trackId,
                playedSeconds: playedSeconds,
                completion: completion
            )
        }
    }

    func applyWaveSettings(_ settings: WaveSettings) async throws {
        try await ensureReady()

        let language: StationPreferredLanguageType = switch settings.language {
        case .any: .any
        case .russian: .russian
        case .notRussian: .not_russian
        }

        let mood: StationMoodType = switch settings.mood {
        case .all: .all
        case .fun: .fun
        case .active: .active
        case .calm: .calm
        case .sad: .sad
        }

        let diversity: StationDiversityType = switch settings.diversity {
        case .default: .defaultDiversity
        case .favorite: .favorite
        case .popular: .popular
        case .discover: .discover
        }

        _ = try await run { completion in
            YMClient.shared.setRadioStationSettings(
                stationId: WaveStation.personal,
                language: language,
                moodEnergy: mood,
                diversity: diversity,
                type: .rotor,
                completion: completion
            )
        }
    }
}
