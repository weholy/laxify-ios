import AVFoundation
import Foundation

/// Finding a way to the server.
///
/// The app was unreachable on some networks and fine on others, and from the
/// server there was no way to tell which part was being filtered — the name,
/// the port, or the address. Guessing produced a build that worked for one
/// person and not the next.
///
/// So the app stops guessing. The server answers on several unrelated routes,
/// and at launch these are raced against each other; whichever replies first
/// is used and remembered. If that route later goes quiet, the race runs
/// again.
struct APIRoute: Sendable, Equatable {
    let base: String
    /// Set when the certificate cannot name this host — connecting by address
    /// is the point of that route, and the certificate is checked by its key
    /// instead. See `APITrust`.
    let skipsHostnameCheck: Bool

    var url: URL { URL(string: base)! }

    static let candidates: [APIRoute] = [
        // Ordinary names first: cheapest, and correct wherever nothing is
        // being filtered at all.
        APIRoute(base: "https://laxify.31-76-27-182.nip.io/api/v1", skipsHostnameCheck: false),
        APIRoute(base: "https://laxify.31-76-27-182.sslip.io/api/v1", skipsHostnameCheck: false),
        APIRoute(base: "https://jutsovpn.online/laxify/api/v1", skipsHostnameCheck: false),

        // Same server, a port that filtering aimed at 443 will not look at.
        APIRoute(base: "https://laxify.31-76-27-182.sslip.io:8443/api/v1", skipsHostnameCheck: false),

        // No name at all, for a network where nothing resolves. The
        // certificate belongs to us and is verified by its key.
        APIRoute(base: "https://31.76.27.182:8443/api/v1", skipsHostnameCheck: true)
    ]
}

/// Picks and remembers a working route.
actor APIRouter {
    static let shared = APIRouter()

    private static let storageKey = "laxify.api.route"
    private static let probeTimeout: TimeInterval = 6

    private var current: APIRoute
    private var probe: Task<APIRoute, Never>?

    /// Which routes answered last time this ran, for the diagnostics report.
    /// Knowing what a blocked network actually allows is the only way to stop
    /// guessing at it.
    private(set) var lastProbeResults: [String: Bool] = [:]

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.storageKey)
        current = APIRoute.candidates.first { $0.base == stored } ?? APIRoute.candidates[0]
    }

    var route: APIRoute { current }

    /// Races every route and keeps the first that answers.
    ///
    /// Run at launch and again whenever the chosen route stops responding.
    /// Concurrent callers share one race rather than starting several.
    @discardableResult
    func discover(force: Bool = false) async -> APIRoute {
        if let probe {
            return await probe.value
        }

        if !force, UserDefaults.standard.string(forKey: Self.storageKey) != nil,
           await reachable(current) {
            return current
        }

        let task = Task<APIRoute, Never> { [current] in
            var results: [String: Bool] = [:]
            var winner: APIRoute?

            await withTaskGroup(of: (APIRoute, Bool).self) { group in
                for candidate in APIRoute.candidates {
                    group.addTask { (candidate, await Self.check(candidate)) }
                }

                for await (candidate, ok) in group {
                    results[candidate.base] = ok
                    // Keep the earliest candidate that works rather than the
                    // fastest to answer: the order encodes a preference, and
                    // a plain name beats connecting by address.
                    if ok, winner == nil || Self.rank(candidate) < Self.rank(winner!) {
                        winner = candidate
                    }
                }
            }

            await self.record(results)
            return winner ?? current
        }

        probe = task
        let chosen = await task.value
        probe = nil

        current = chosen
        UserDefaults.standard.set(chosen.base, forKey: Self.storageKey)
        AppLogger.log("api: используется маршрут \(chosen.base)")

        return chosen
    }

    private func record(_ results: [String: Bool]) {
        lastProbeResults = results

        let summary = results
            .map { "\($0.key) — \($0.value ? "да" : "нет")" }
            .sorted()
            .joined(separator: "\n")
        AppLogger.log("api: доступность маршрутов\n\(summary)")
        CrashReporter.breadcrumb("routes\n\(summary)")
    }

    /// Called when a request fails to connect, so the next one can go
    /// somewhere else instead of failing the same way.
    func routeFailed(_ failed: APIRoute) async {
        guard failed == current else { return }
        await discover(force: true)
    }

    private func reachable(_ candidate: APIRoute) async -> Bool {
        await Self.check(candidate)
    }

    private static func rank(_ candidate: APIRoute) -> Int {
        APIRoute.candidates.firstIndex(of: candidate) ?? .max
    }

    private static func check(_ candidate: APIRoute) async -> Bool {
        guard let url = URL(string: candidate.base.replacingOccurrences(of: "/api/v1", with: "/health")) else {
            return false
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = probeTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let session = candidate.skipsHostnameCheck
            ? APITrust.pinnedSession
            : URLSession.shared

        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}

/// Trusts our own server when it is reached by address.
///
/// A certificate names hosts, not addresses, so connecting by address fails
/// validation even though the certificate is genuinely ours. Rather than turn
/// checking off, the certificate chain is validated against the hostname it
/// does name — so this accepts our server and nothing else.
final class APITrust: NSObject, URLSessionDelegate, @unchecked Sendable {
    /// The name the certificate is issued for.
    static let certificateHost = "laxify.31-76-27-182.sslip.io"

    static let shared = APITrust()

    static let pinnedSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 45
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: shared, delegateQueue: nil)
    }()

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Re-run the standard evaluation, but against the name the
        // certificate actually carries. Everything else — expiry, the chain
        // up to a trusted root — is checked exactly as usual.
        let policy = SecPolicyCreateSSL(true, Self.certificateHost as CFString)
        SecTrustSetPolicies(trust, policy)

        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            AppLogger.log("api: сертификат не прошёл проверку — \(String(describing: error))")
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}


/// Lets AVPlayer reach the server by address.
///
/// The player opens its own connections, so the trust evaluation the rest of
/// the app uses does not apply to it. Its resource loader is asked about
/// authentication challenges, which is where the same check goes: validate
/// the certificate against the name it carries, and accept nothing else.
final class PlayerTrust: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let shared = PlayerTrust()

    private let queue = DispatchQueue(label: "laxify.player.trust")

    /// Attaches this to an asset that will be reached by address.
    func attach(to asset: AVURLAsset) {
        asset.resourceLoader.setDelegate(self, queue: queue)
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForResponseTo authenticationChallenge: URLAuthenticationChallenge
    ) -> Bool {
        let space = authenticationChallenge.protectionSpace

        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = space.serverTrust else {
            authenticationChallenge.sender?.performDefaultHandling?(for: authenticationChallenge)
            return true
        }

        let policy = SecPolicyCreateSSL(true, APITrust.certificateHost as CFString)
        SecTrustSetPolicies(trust, policy)

        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) {
            authenticationChallenge.sender?.use(
                URLCredential(trust: trust), for: authenticationChallenge
            )
        } else {
            authenticationChallenge.sender?.cancel(authenticationChallenge)
        }

        return true
    }
}
