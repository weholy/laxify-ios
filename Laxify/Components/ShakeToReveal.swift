import SwiftUI
import UIKit

extension Notification.Name {
    static let laxifyDeviceShaken = Notification.Name("laxify.device.shaken")
}

/// iOS reports a shake as a discrete motion event on the responder chain, and
/// the only place to catch it without owning a view controller is the window.
extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        super.motionEnded(motion, with: event)
        guard motion == .motionShake else { return }
        NotificationCenter.default.post(name: .laxifyDeviceShaken, object: nil)
    }
}

/// Opens something after the phone has been shaken for a few seconds.
///
/// A single shake is easy to trigger by accident — putting the phone in a
/// pocket does it. Sustained shaking does not happen unless it is meant, so
/// the gesture is counted rather than detected: several shakes inside one
/// window, or nothing.
struct ShakeToReveal: ViewModifier {
    /// How many shake events, and inside how long, count as deliberate.
    var required = 3
    var window: TimeInterval = 3

    var action: () -> Void

    @State private var marks: [Date] = []

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .laxifyDeviceShaken)) { _ in
            let now = Date()
            marks.append(now)
            marks = marks.filter { now.timeIntervalSince($0) <= window }

            guard marks.count >= required else { return }
            marks.removeAll()

            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            action()
        }
    }
}

extension View {
    func onShake(required: Int = 3, within window: TimeInterval = 3, perform action: @escaping () -> Void) -> some View {
        modifier(ShakeToReveal(required: required, window: window, action: action))
    }
}
