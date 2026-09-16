import SwiftUI
import UIKit

/// The system share sheet, for the moments a `ShareLink` cannot do the job —
/// `ShareLink` presents when tapped, and nothing here can be shown until an
/// async download finishes, so this needs to be a sheet driven by state
/// instead.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
