import SwiftUI
import AVKit

/// The system's output picker, wearing headphones.
///
/// `AVRoutePickerView` is the only way to raise iOS's route sheet — the one
/// that lists Bluetooth headphones, speakers and the phone itself — but it
/// insists on drawing AirPlay's triangle and offers no way to change it. So
/// the picker is laid over our own glyph at an opacity low enough to be
/// invisible and high enough that UIKit still hit-tests it: the headphones are
/// what you see, the system sheet is what you get.
struct AirPlayRouteButton: View {
    /// What is playing the sound right now, so the glyph can say so.
    ///
    /// The route sheet is the same one either way — it lists Bluetooth
    /// headphones, speakers and the phone itself — but a button that always
    /// showed headphones read as AirPlay. Showing the *current* route, and
    /// tinting it when the sound has left the phone, makes it obvious that
    /// this is where devices are chosen.
    @State private var route = OutputRoute.current()

    var body: some View {
        ZStack {
            Image(systemName: route.symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(route.isExternal ? LaxifyPalette.accent : .white.opacity(0.75))
                .contentTransition(.symbolEffect(.replace))

            RoutePicker()
                // Below 0.01 UIKit stops delivering touches.
                .opacity(0.02)
        }
        .frame(width: LaxifyMetrics.controlSize, height: LaxifyMetrics.controlSize)
        .contentShape(Rectangle())
        .accessibilityLabel(route.name)
        .onReceive(
            NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
        ) { _ in
            withAnimation(.snappy(duration: 0.25)) { route = OutputRoute.current() }
        }
    }
}

/// Where the sound is going, in the two terms the button needs.
struct OutputRoute {
    let symbol: String
    let name: String
    let isExternal: Bool

    @MainActor
    static func current() -> OutputRoute {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs

        guard let output = outputs.first else {
            return OutputRoute(
                symbol: "headphones",
                name: L("player.output", "Устройство вывода"),
                isExternal: false
            )
        }

        switch output.portType {
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE:
            return OutputRoute(symbol: "headphones", name: output.portName, isExternal: true)
        case .airPlay:
            return OutputRoute(symbol: "airplayaudio", name: output.portName, isExternal: true)
        case .headphones, .usbAudio:
            return OutputRoute(symbol: "headphones", name: output.portName, isExternal: true)
        case .carAudio:
            return OutputRoute(symbol: "car.fill", name: output.portName, isExternal: true)
        default:
            // The phone's own speaker: offer the sheet rather than announce it.
            return OutputRoute(
                symbol: "airpods.gen3",
                name: L("player.output", "Устройство вывода"),
                isExternal: false
            )
        }
    }
}

private struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView(frame: .zero)
        view.tintColor = .white
        view.activeTintColor = UIColor(LaxifyPalette.accent)
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
