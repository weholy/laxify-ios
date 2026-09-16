import Foundation

/// Whether the phone's own connection to the music source is working right
/// now.
///
/// On some networks it intermittently is not. The logs from two weeks of real
/// listening show the same error again and again — a secure connection that
/// could not be established, over a hundred times, on connections that were
/// otherwise up — which is what a network that interferes with particular
/// hosts looks like from the inside. Every track that went the direct way
/// first on such a network waited out a full timeout before trying the
/// server, and a wait that long is a skip in all but name.
///
/// So failures are counted, and after two close together the server is tried
/// first for a few minutes. It is never a permanent decision: the state lapses
/// on its own, and the first direct success clears it.
enum DirectRouteHealth {
    private static let lock = NSLock()

    nonisolated(unsafe) private static var recentFailures: [Date] = []
    nonisolated(unsafe) private static var degradedUntil: Date = .distantPast

    /// Two failures inside this window make a pattern rather than a hiccup.
    private static let window: TimeInterval = 180
    /// How long the server goes first once a pattern is seen.
    private static let cooldown: TimeInterval = 300

    static var isDegraded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return Date() < degradedUntil
    }

    static func failed() {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        recentFailures = recentFailures.filter { now.timeIntervalSince($0) < window }
        recentFailures.append(now)

        guard recentFailures.count >= 2, now >= degradedUntil else { return }
        degradedUntil = now.addingTimeInterval(cooldown)

        RemoteLog.shared.warn(
            "прямой путь к источнику сбоит — сначала сервер",
            category: "playback",
            context: ["минут": "\(Int(cooldown / 60))"]
        )
    }

    static func succeeded() {
        lock.lock()
        defer { lock.unlock() }

        recentFailures.removeAll()
        degradedUntil = .distantPast
    }

    /// Whether a playback error from the player is the network rather than
    /// the audio. Only those count against the direct route.
    static func isNetworkFailure(_ error: Error?) -> Bool {
        guard let error else { return false }

        var current: NSError? = error as NSError
        // The player wraps the real cause, sometimes twice.
        for _ in 0..<3 {
            guard let found = current else { break }
            if found.domain == NSURLErrorDomain {
                switch found.code {
                case NSURLErrorSecureConnectionFailed, NSURLErrorTimedOut,
                     NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost,
                     NSURLErrorNotConnectedToInternet, NSURLErrorCannotFindHost,
                     NSURLErrorDNSLookupFailed, NSURLErrorServerCertificateUntrusted:
                    return true
                default:
                    break
                }
            }
            current = found.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
}
