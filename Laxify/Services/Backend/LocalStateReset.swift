import Foundation
import SwiftData

/// Wipes everything belonging to the account that just signed out.
///
/// Signing out only dropped the tokens, so the next account inherited the
/// previous one's favourites, listening time, downloads and cached feed —
/// and then the migration step pushed all of it onto the new account as if
/// it were theirs. One person's library ended up on someone else's profile.
///
/// Anything account-shaped is cleared here. Device preferences — theme, which
/// host answered — belong to the phone rather than the person, and stay.
@MainActor
enum LocalStateReset {
    /// Keys holding one person's data.
    private static let accountKeys = [
        "laxify.session.user",
        "laxify.home.tracks",
        "laxify.home.wave",
        "laxify.home.savedAt",
        "laxify.signin.covers",
        "laxify.stats.totalSeconds",
        "laxify.sync.outbox",
        "laxify.wave.settings"
    ]

    /// Deliberately kept: these describe the device, not the account, and
    /// clearing them would reset the theme and re-discover the API host on
    /// every sign-out.
    private static let devicePreferences = [
        "laxify.appearance.theme",
        "laxify.appearance.animations",
        "laxify.api.host",
        "laxify.device.uuid"
    ]

    static func performOnSignOut(context: ModelContext?) {
        let defaults = UserDefaults.standard
        for key in accountKeys {
            defaults.removeObject(forKey: key)
        }

        // A queued like belonging to the previous account must never be
        // delivered under the next one's token.
        SyncOutbox.shared.clear()

        ListeningStatsService.shared.reset()
        DownloadManager.shared.removeAll()
        AudioPlayerController.shared.stopAndClear()

        clearStore(context)
    }

    /// Removes the on-device library.
    ///
    /// These rows predate accounts and are still what the app reads while
    /// offline, so they are per-person and have to go with the person.
    private static func clearStore(_ context: ModelContext?) {
        guard let context else { return }

        do {
            try context.delete(model: FavoriteTrack.self)
            try context.delete(model: DislikedTrack.self)
            try context.delete(model: SearchHistoryEntry.self)
            try context.save()
        } catch {
            AppLogger.log("signout: не удалось очистить локальную библиотеку — \(error)")
        }
    }

    /// True when this device has local data that predates any account.
    ///
    /// Only that is worth migrating. Sending an empty set, or one that a
    /// previous account left behind, is how libraries crossed over.
    static func hasUnmigratedLocalData(favorites: Int, dislikes: Int, seconds: Double) -> Bool {
        favorites > 0 || dislikes > 0 || seconds > 0
    }
}
