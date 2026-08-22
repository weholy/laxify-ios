import AppIntents

/// Controls exposed on the Live Activity.
///
/// `LiveActivityIntent` runs in the host app's process rather than the
/// extension's, which is what lets these reach the running player directly
/// instead of going through a shared file or a notification round trip.
///
/// The types are compiled into both targets so the widget can build its
/// buttons, but the bodies are compiled out of the extension, which has no
/// player to talk to.
struct TogglePlaybackIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Плей/пауза"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await AudioPlayerController.shared.togglePlayPause()
        #endif
        return .result()
    }
}

struct NextTrackIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Следующий трек"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await AudioPlayerController.shared.next()
        #endif
        return .result()
    }
}

struct PreviousTrackIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Предыдущий трек"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await AudioPlayerController.shared.previous()
        #endif
        return .result()
    }
}

struct ToggleFavoriteIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "В избранное"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await FavoriteToggler.shared.toggleCurrent()
        #endif
        return .result()
    }
}
