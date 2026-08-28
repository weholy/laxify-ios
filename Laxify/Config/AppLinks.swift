import Foundation

/// Outward links the app points people at. Kept in one place so they are easy
/// to change without hunting through views.
enum AppLinks {
    /// The project's Telegram channel — announcements, new builds.
    static let telegramChannel = URL(string: "https://t.me/laxifyapp")!

    /// Where "поддержать проект" goes.
    static let support = URL(string: "https://t.me/laxifyapp")!

    /// Bot used for Telegram sign-in and subscription confirmation (later).
    static let telegramBot = "laxifyapp_bot"
}
