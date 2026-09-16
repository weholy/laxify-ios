import SafariServices
import SwiftUI

/// A page from the web, opened inside the app.
///
/// The system's own Safari view rather than a web view of ours: it is the
/// thing people recognise, it carries its own address bar, reader mode and
/// share button, and it never gives the app access to what is typed into it.
/// Leaving the app for Safari to read two paragraphs of terms lost people's
/// place — this keeps them where they were.
struct InAppBrowser: UIViewControllerRepresentable {
    let url: URL
    /// Called when the person taps the browser's own Done button.
    var onFinish: () -> Void = {}
    /// Called once the first page has either loaded or failed to.
    var onInitialLoad: (Bool) -> Void = { _ in }

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        configuration.barCollapsingEnabled = true

        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.dismissButtonStyle = .close
        controller.preferredControlTintColor = UIColor(LaxifyPalette.accent)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        var parent: InAppBrowser

        init(parent: InAppBrowser) {
            self.parent = parent
        }

        nonisolated func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            MainActor.assumeIsolated { parent.onFinish() }
        }

        nonisolated func safariViewController(
            _ controller: SFSafariViewController,
            didCompleteInitialLoad didLoadSuccessfully: Bool
        ) {
            MainActor.assumeIsolated { parent.onInitialLoad(didLoadSuccessfully) }
        }
    }
}
