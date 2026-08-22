import AVFoundation
import MediaPlayer
import SwiftUI

/// Reads and writes the system output volume behind a custom slider.
///
/// Reading is straightforward through `AVAudioSession`. Writing has no public
/// API at all — the only supported route is `MPVolumeView`, so one is kept
/// off-screen purely to drive its embedded slider. That keeps the visible
/// control ours while the actual volume change still goes through the system.
@MainActor
@Observable
final class VolumeController {
    static let shared = VolumeController()

    private(set) var volume: Double = 0

    private let hiddenVolumeView = MPVolumeView(frame: .zero)
    private var observation: NSKeyValueObservation?
    private var isApplyingLocally = false

    private init() {
        let session = AVAudioSession.sharedInstance()
        volume = Double(session.outputVolume)

        observation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let newValue = change.newValue else { return }
            Task { @MainActor in
                guard let self, !self.isApplyingLocally else { return }
                self.volume = Double(newValue)
            }
        }
    }

    /// Must be placed in the view hierarchy (zero-sized) for setting to work:
    /// an `MPVolumeView` that was never added to a window does nothing.
    var hostView: some View {
        VolumeHost(view: hiddenVolumeView)
            .frame(width: 0, height: 0)
            .opacity(0)
            .allowsHitTesting(false)
    }

    func setVolume(_ newValue: Double) {
        let clamped = min(max(newValue, 0), 1)
        volume = clamped

        guard let slider = hiddenVolumeView.subviews.compactMap({ $0 as? UISlider }).first else {
            return
        }

        // The system echoes the change back through KVO; ignore that echo or
        // the slider stutters against the finger.
        isApplyingLocally = true
        slider.setValue(Float(clamped), animated: false)
        slider.sendActions(for: .valueChanged)

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            isApplyingLocally = false
        }
    }
}

private struct VolumeHost: UIViewRepresentable {
    let view: MPVolumeView

    func makeUIView(context: Context) -> MPVolumeView {
        view.showsRouteButton = false
        view.isHidden = false
        view.alpha = 0.001
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
