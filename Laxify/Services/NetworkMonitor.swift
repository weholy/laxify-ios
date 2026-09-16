import Foundation
import Network

/// Notices when the phone's network changes — a VPN switched on or off, Wi-Fi
/// to cellular, a connection coming back.
///
/// Nothing in the app used to. The route to our server was chosen once and
/// remembered, and only looked for again after a request had already failed,
/// at most once a minute; the phone's own connection to the music source kept
/// its record of recent failures from the network it had just left. Turning a
/// VPN on or off therefore left the app talking the way that suited the
/// *previous* network for a minute or more — "sometimes it works with the
/// VPN, sometimes without, sometimes differently" was mostly that minute.
///
/// On a real change the route is raced again straight away and old failures
/// are forgotten. `generation` bumps too, so anything that failed to load on
/// the old network — a cover, a feed — can try again on the new one.
@MainActor
@Observable
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    /// Increments on every meaningful change of network.
    private(set) var generation = 0
    private(set) var isConnected = true

    private let monitor = NWPathMonitor()
    private var lastSignature: String?

    private init() {}

    func start() {
        monitor.pathUpdateHandler = { path in
            // Interface names and types together: a VPN appears as an extra
            // interface (`utun…`, `ipsec…`), which the status alone never
            // shows — the phone is "connected" before and after.
            let signature = [
                path.status == .satisfied ? "up" : "down",
                path.isExpensive ? "exp" : "",
                path.availableInterfaces
                    .map { "\($0.name):\($0.type)" }
                    .sorted()
                    .joined(separator: ",")
            ].joined(separator: "|")
            let connected = path.status == .satisfied

            Task { @MainActor in
                NetworkMonitor.shared.handle(signature: signature, connected: connected)
            }
        }
        monitor.start(queue: DispatchQueue(label: "laxify.network.monitor"))
    }

    private func handle(signature: String, connected: Bool) {
        isConnected = connected

        // The first reading is where we are, not a change.
        guard let previous = lastSignature else {
            lastSignature = signature
            return
        }
        guard previous != signature else { return }
        lastSignature = signature

        generation += 1
        RemoteLog.shared.info(
            "сеть сменилась",
            category: "network",
            context: ["подключено": "\(connected)"]
        )

        guard connected else { return }

        // Whatever the old network allowed says nothing about this one.
        DirectRouteHealth.succeeded()
        Task {
            await APIRouter.shared.discover(force: true)
            await LaxifyAPI.shared.adoptCurrentRoute()
        }
    }
}
