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
/// failure, but the same handful of failures arriving over and over. Once a
/// track has failed with no substitute, it is written down here and never
/// listed again.
///
/// Read on every row of every listing, and from whichever thread is decoding
/// it, so the answer is held in memory behind a lock rather than rebuilt from
/// `UserDefaults` each time.
enum UnplayableStore {
    private static let state = State()

    static func contains(_ trackId: String) -> Bool {
        state.contains(trackId)
    }

    static func remember(_ trackId: String) {
        state.remember(trackId)
    }

    /// Forgets everything.
    ///
    /// Not wired to signing out: what a track does is a fact about the
    /// catalogue, not about whose account is on the phone, and throwing it
    /// away would only mean rediscovering the same dead tracks the hard way.
    /// Here because the source does change what it serves — a track locked
    /// today can be free next month — so there has to be a way back.
    static func clear() {
        state.clear()
    }

    /// The set itself, its ordering, and the lock over both.
    private final class State: @unchecked Sendable {
        private let key = "laxify.unplayable.trackIds"
        /// Enough for years of ordinary listening; past it the oldest go, so
        /// a long-lived install cannot grow this without limit.
        private let cap = 2000

        private let lock = NSLock()
        private var ids: Set<String>
        /// Insertion order, so trimming drops the oldest rather than an
        /// arbitrary member of a set.
        private var order: [String]

        init() {
            let stored = UserDefaults.standard.stringArray(forKey: key) ?? []
            order = stored
            ids = Set(stored)
        }

        func contains(_ trackId: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return ids.contains(trackId)
        }

        func remember(_ trackId: String) {
            guard !trackId.isEmpty else { return }

            lock.lock()
            defer { lock.unlock() }

            guard !ids.contains(trackId) else { return }

            ids.insert(trackId)
            order.append(trackId)

            if order.count > cap {
                let excess = order.count - cap
                for id in order.prefix(excess) { ids.remove(id) }
                order.removeFirst(excess)
            }

            UserDefaults.standard.set(order, forKey: key)
        }

        func clear() {
            lock.lock()
            defer { lock.unlock() }

            ids = []
            order = []
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
