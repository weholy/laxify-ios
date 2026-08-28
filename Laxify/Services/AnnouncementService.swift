import Foundation

struct Announcement: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let body: String
    let cta: String
}

/// The "what's new" card shown once after each update.
///
/// The copy is local for now; `refresh()` is where a backend-served
/// announcement will slot in without touching the call sites. "Once per
/// version" falls out of the id carrying the build number.
@MainActor
@Observable
final class AnnouncementService {
    static let shared = AnnouncementService()

    private(set) var current: Announcement?

    private static let seenKey = "laxify.announcement.seen"

    private init() {
        let local = Self.localAnnouncement
        if UserDefaults.standard.string(forKey: Self.seenKey) != local.id {
            current = local
        }
    }

    func markSeen() {
        guard let current else { return }
        UserDefaults.standard.set(current.id, forKey: Self.seenKey)
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
