import Foundation

/// Outward links the app points people at. Kept in one place so they are easy
/// to change without hunting through views.
enum AppLinks {
    /// The project's Telegram channel — announcements, new builds.
    static let telegramChannel = URL(string: "https://t.me/laxifyapp")!

    /// Where "поддержать проект" goes — the author, directly.
    static let support = URL(string: "https://t.me/skyredy")!

    /// Where "связаться с нами" goes — the project's own channel.
    static let contact = URL(string: "https://t.me/laxify")!

    /// The project's own site. Terms and the privacy note live there, and are
    /// opened in the in-app browser rather than kept only as text in the app,
    /// so they can change without a new build.
    static let website = URL(string: "https://laxify.cc")!
    // laxify.cc does not resolve yet, which made TermsView's browser flash
    // and fall back to its built-in text every time. Pointed at a page that
    // reliably loads until the real site is live — swap back once it is.
    static let terms = URL(string: "https://t.me/skyredy")!
    static let privacy = URL(string: "https://t.me/skyredy")!

    /// Bot used for Telegram sign-in and subscription confirmation (later).
    static let telegramBot = "LaxifyAppBot"

    /// The Telegram Login Widget bridge page. Must stay this exact host — it
    /// is what @BotFather has registered for the bot via /setdomain, and the
    /// widget refuses to load anywhere else.
    static let telegramLoginPage = URL(string: "https://laxify.31-76-27-182.sslip.io/tg-login")!
}
