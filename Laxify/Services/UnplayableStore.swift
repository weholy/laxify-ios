import Foundation

/// Tracks this device has proven cannot be played, remembered between
/// launches.
///
/// Some tracks cannot be rescued. The source serves them under DRM, and for
/// part of the catalogue there is no second upload of the same recording to
/// fall back to — measured across a sample of Western major-label releases,
/// every playable copy was a remix, a flip or an instrumental, none of them
/// the song. Substitution correctly refuses those, and then there is nothing
/// left to play.
///
/// What must not happen is meeting the same dead track again tomorrow. It was
/// only ever skipped for the session and then offered again on the next
/// launch, which is what "tracks keep getting skipped" is made of: not one
/// failure, but the same handful of failures arriving over and over.
///
/// The other thing that must not happen — and did — is a track being struck
/// off **for good** over a bad minute. Every failure used to land here, a
/// throttled source and a dropped connection included, and the entry never
/// expired: one evening on a weak network quietly deleted dozens of working
/// songs from every listing in the app, permanently, with nothing anywhere
/// to undo it. So two things changed. A verdict now has to be *definitive* —
/// the source itself said this recording has no playable copy — before it
/// bars anything, and anything short of that only leaves a strike. And no
/// verdict is forever: they all age out and the track is tried again.
///
/// Read on every row of every listing, and from whichever thread is decoding
/// it, so the answer is held in memory behind a lock rather than rebuilt from
/// `UserDefaults` each time.
enum UnplayableStore {
    private static let state = State()

    /// How long a definitive verdict stands before the track is offered
    /// again. The source does change what it serves — a track locked today
    /// can be free next month — so this is a pause, never a deletion.
    static let definitiveTTL: TimeInterval = 14 * 24 * 3600
    /// A track that merely keeps failing is set aside for the afternoon, not
    /// the fortnight.
    static let strikeTTL: TimeInterval = 6 * 3600
    /// How many soft failures it takes. Three, because the player already
    /// retries within a single play: reaching three means three separate
    /// occasions, not three moments of one bad connection.
    static let strikesBeforeHiding = 3

    static func contains(_ trackId: String) -> Bool {
        state.isHidden(trackId)
    }

    /// The source answered, and the answer was that there is nothing playable
    /// here — DRM with no substitute anywhere, or an upload that no longer
    /// exists. Only this bars a track.
    static func remember(_ trackId: String) {
        state.bar(trackId, for: definitiveTTL)
    }

    /// Something went wrong and we could not tell whose fault it was. Counted,
    /// not acted on, until it has happened often enough to be a pattern.
    static func strike(_ trackId: String) {
        state.strike(trackId)
    }

    /// The track played after all — forget every strike against it.
    static func absolve(_ trackId: String) {
        state.absolve(trackId)
    }

    /// Forgets everything.
    ///
    /// Not wired to signing out: what a track does is a fact about the
    /// catalogue, not about whose account is on the phone. Wired to the
    /// diagnostics screen instead, so a listener who thinks the app is
    /// hiding music from them can prove it either way in one tap.
    static func clear() {
        state.clear()
    }

    /// How many tracks are set aside right now, for that screen to show.
    static var hiddenCount: Int { state.hiddenCount }

    // MARK: - Storage

    private struct Entry: Codable {
        /// When the track becomes eligible again. Zero while it is only
        /// carrying strikes and is still being offered.
        var hiddenUntil: TimeInterval
        var strikes: Int
        var lastFailureAt: TimeInterval
    }

    /// The entries, their ordering, and the lock over both.
    private final class State: @unchecked Sendable {
        private let key = "laxify.unplayable.v2"
        /// The set this replaced. Read once and thrown away rather than
        /// migrated: it was filled by the very rule that has just been
        /// removed, so every id in it is as likely to be a working song that
        /// met a bad network as it is to be a dead upload. Keeping it would
        /// carry the bug forward into the fix.
        private let retiredKey = "laxify.unplayable.trackIds"

        /// Enough for years of ordinary listening; past it the oldest go, so
        /// a long-lived install cannot grow this without limit.
        private let cap = 2000

        private let lock = NSLock()
        private var entries: [String: Entry]
        /// Insertion order, so trimming drops the oldest rather than an
        /// arbitrary member.
        private var order: [String]

        init() {
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: retiredKey)

            if let data = defaults.data(forKey: key),
               let stored = try? JSONDecoder().decode(Stored.self, from: data) {
                entries = stored.entries
                order = stored.order.filter { stored.entries[$0] != nil }
            } else {
                entries = [:]
                order = []
            }
        }

        private struct Stored: Codable {
            var entries: [String: Entry]
            var order: [String]
        }

        func isHidden(_ trackId: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }

            guard let entry = entries[trackId] else { return false }
            guard entry.hiddenUntil > Date().timeIntervalSince1970 else {
                // Its time is up. Dropped here rather than left to a sweep,
                // so the very next listing shows the track again.
                if entry.strikes == 0 { forget(trackId) } else { entries[trackId]?.hiddenUntil = 0 }
                save()
                return false
            }
            return true
        }

        func bar(_ trackId: String, for interval: TimeInterval) {
            guard !trackId.isEmpty else { return }

            lock.lock()
            defer { lock.unlock() }

            let now = Date().timeIntervalSince1970
            var entry = entries[trackId] ?? Entry(hiddenUntil: 0, strikes: 0, lastFailureAt: now)
            entry.hiddenUntil = now + interval
            entry.lastFailureAt = now
            put(trackId, entry)
            save()
        }

        func strike(_ trackId: String) {
            guard !trackId.isEmpty else { return }

            lock.lock()
            defer { lock.unlock() }

            let now = Date().timeIntervalSince1970
            var entry = entries[trackId] ?? Entry(hiddenUntil: 0, strikes: 0, lastFailureAt: now)

            // Strikes only count while they are recent. Two failures a month
            // apart are two bad evenings, not a dead track.
            if now - entry.lastFailureAt > UnplayableStore.strikeTTL { entry.strikes = 0 }

            entry.strikes += 1
            entry.lastFailureAt = now
            if entry.strikes >= UnplayableStore.strikesBeforeHiding {
                entry.hiddenUntil = now + UnplayableStore.strikeTTL
            }
            put(trackId, entry)
            save()
        }

        func absolve(_ trackId: String) {
            lock.lock()
            defer { lock.unlock() }

            guard entries[trackId] != nil else { return }
            forget(trackId)
            save()
        }

        func clear() {
            lock.lock()
            defer { lock.unlock() }

            entries = [:]
            order = []
            UserDefaults.standard.removeObject(forKey: key)
        }

        var hiddenCount: Int {
            lock.lock()
            defer { lock.unlock() }

            let now = Date().timeIntervalSince1970
            return entries.values.filter { $0.hiddenUntil > now }.count
        }

        // MARK: - Called with the lock held

        private func put(_ trackId: String, _ entry: Entry) {
            if entries[trackId] == nil { order.append(trackId) }
            entries[trackId] = entry

            if order.count > cap {
                let excess = order.count - cap
                for id in order.prefix(excess) { entries[id] = nil }
                order.removeFirst(excess)
            }
        }

        private func forget(_ trackId: String) {
            entries[trackId] = nil
            order.removeAll { $0 == trackId }
        }

        private func save() {
            guard let data = try? JSONEncoder().encode(Stored(entries: entries, order: order))
            else { return }
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
