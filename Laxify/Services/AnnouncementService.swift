import Foundation

struct Announcement: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let body: String
    let cta: String
}

/// The "what's new" card shown once after an update.
///
/// The copy is local for now; `refresh()` is where a backend-served
/// announcement will slot in without touching the call sites.
///
/// "Seen" lives in the keychain, which survives an uninstall/reinstall —
/// otherwise every sideloaded build re-showed the same card. A first-ever
/// launch records the current card silently: someone installing the app for
/// the first time does not need to be told what changed.
@MainActor
@Observable
final class AnnouncementService {
    static let shared = AnnouncementService()

    private(set) var current: Announcement?

    private static let legacySeenKey = "laxify.announcement.seen"

    private init() {
        let local = Self.localAnnouncement

        var seen = KeychainStore.read(.announcementSeen)
        if seen == nil, let legacy = UserDefaults.standard.string(forKey: Self.legacySeenKey) {
            // Carry over a dismissal from before this moved to the keychain.
            KeychainStore.save(legacy, for: .announcementSeen)
            seen = legacy
        }

        guard let seen else {
            // Nothing on record: first install ever, or the keychain was
            // wiped. Don't greet a new user with a changelog.
            KeychainStore.save(local.id, for: .announcementSeen)
            return
        }

        if seen != local.id {
            current = local
        }
    }

    func markSeen() {
        guard let current else { return }
        KeychainStore.save(current.id, for: .announcementSeen)
        UserDefaults.standard.set(current.id, forKey: Self.legacySeenKey)
        self.current = nil
    }

    /// Placeholder for a server-served announcement — same shape, replaces
    /// `current` when it arrives and is newer than what's been seen.
    func refresh() async {}

    private static var localAnnouncement: Announcement {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return Announcement(
            id: "welcome-\(version).\(build)",
            title: "Laxify обновился",
            body: """
            Спасибо, что вы с нами на раннем этапе. Уже здесь: своя волна как \
            отдельная вкладка, поиск с категориями, плейлисты и четыре языка \
            интерфейса. Дальше — комментарии, статистика и больше.

            Идеи и баги пишите в Telegram-канале — на них правда смотрят.
            """,
            cta: "Понятно"
        )
    }
}
