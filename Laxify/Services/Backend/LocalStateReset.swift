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
        "laxify.session.guest",
        "laxify.home.tracks",
        "laxify.home.wave",
        "laxify.home.savedAt",
        "laxify.browse.popular",
        "laxify.browse.categories",
        "laxify.browse.savedAt",
        "laxify.signin.covers",
        "laxify.stats.totalSeconds",
        "laxify.stats.repairedTrackIds",
        "laxify.play.recorded",
        "laxify.playlists.cache",
        "laxify.sync.outbox",
        "laxify.wave.settings",
        "laxify.wave.batchId",
        "laxify.history.mirroredAt",
        lastAccountKey
    ]

    /// Deliberately kept: these describe the device, not the account, and
    /// clearing them would reset the theme and re-discover the API host on
    /// every sign-out.
    private static let devicePreferences = [
        "laxify.appearance.theme",
        "laxify.api.host",
        "laxify.api.route",
        "laxify.device.uuid",
        "laxify.language",
        "laxify.language.picked"
    ]

    /// Whose data is on this phone right now.
    ///
    /// Written on every sign-in and read on the next one. Without it the app
    /// had no way to notice that the person signing in was not the person
    /// whose library was still here — which is exactly what happened
    /// whenever an account ended some way other than the sign-out button: a
    /// session expiring on the server, a ban, an account deleted from the
    /// admin panel. None of those ran the wipe, so "sometimes the previous
    /// account's cache is still there".
    private static let lastAccountKey = "laxify.device.lastAccountId"

    static func performOnSignOut(context: ModelContext?) {
        let defaults = UserDefaults.standard
        for key in accountKeys {
            defaults.removeObject(forKey: key)
        }

        // A queued like belonging to the previous account must never be
        // delivered under the next one's token.
        SyncOutbox.shared.clear()
        SyncService.shared.reset()

        ListeningStatsService.shared.reset()
        AudioPlayerController.shared.stopAndClear()

        // The singletons outlive any one account, so what they hold in memory
        // has to be let go of explicitly — the disk caches behind them are
        // only half of it.
        PlaylistStore.shared.reset()
        PlaylistPreviewStore.shared.reset()
        NotificationStore.shared.reset()
        DeepLinkRouter.shared.reset()

        // Downloads are the previous person's library too: their rows, and
        // the files behind them.
        DownloadManager.shared.removeAll()
        AudioCache.removeAll()

        clearStore(context)
    }

    /// Called with the account that has just signed in, before anything of
    /// theirs is written.
    ///
    /// When the phone still holds a different account's data, that data goes
    /// first. The comparison uses whichever record of the previous owner is
    /// available: the id this remembers, or — on a phone updated from a
    /// version that never remembered one — the profile that was cached.
    ///
    /// A phone with no previous owner at all is left alone: that is someone
    /// who listened without an account, and their library is meant to move
    /// onto the account they are creating.
    static func prepareForAccount(_ accountId: String, previouslyCached: String?, context: ModelContext?) {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: lastAccountKey) ?? previouslyCached

        if let previous, !previous.isEmpty, previous != accountId {
            AppLogger.log("session: на устройстве данные другого аккаунта — очищаем перед входом")
            performOnSignOut(context: context)
        }

        defaults.set(accountId, forKey: lastAccountKey)
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
            // Statistics are worked out from these, so leaving them behind
            // showed the next person to sign in the previous one's listening
            // — the same leak favourites had, in a newer table.
            try context.delete(model: PlayRecord.self)
            try context.delete(model: DownloadedTrack.self)
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
