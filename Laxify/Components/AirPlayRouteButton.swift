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
    var body: some View {
        ZStack {
            Image(systemName: "headphones")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))

            RoutePicker()
                // Below 0.01 UIKit stops delivering touches.
                .opacity(0.02)
        }
        .frame(width: 40, height: 40)
        .contentShape(Rectangle())
        .accessibilityLabel(L("player.output", "Устройство вывода"))
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
