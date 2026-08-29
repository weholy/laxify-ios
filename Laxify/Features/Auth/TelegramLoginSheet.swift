import SwiftUI
import WebKit

/// Loads the backend's `/tg-login` bridge in a web view and hands back the
/// signed Telegram Login Widget payload once the page bounces it to
/// `laxify://auth/telegram?...`.
struct TelegramLoginSheet: View {
    /// The raw widget fields, `hash` included.
    var onResult: ([String: String]) -> Void
    var onCancel: () -> Void

    @State private var isLoading = true
    @State private var failed = false

    var body: some View {
        NavigationStack {
            ZStack {
                LaxifyPalette.background.ignoresSafeArea()

                TelegramLoginWebView(
                    url: AppLinks.telegramLoginPage,
                    onPayload: onResult,
                    onLoadingChange: { isLoading = $0 },
                    onFailure: { failed = true; isLoading = false }
                )
                .opacity(failed ? 0 : 1)
                .ignoresSafeArea(edges: .bottom)

                if isLoading {
                    ProgressView().tint(LaxifyPalette.textSecondary)
                }

                if failed {
                    VStack(spacing: 8) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.system(size: 34))
                            .foregroundStyle(LaxifyPalette.textTertiary)
                        Text(L("signin.telegram.failed", "Не удалось открыть вход через Telegram"))
                            .font(LaxifyTypography.footnote)
                            .foregroundStyle(LaxifyPalette.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 40)
                }
            }
            .navigationTitle(L("signin.telegram.title", "Вход через Telegram"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.cancel", "Отмена"), action: onCancel)
                }
            }
        }
    }
}

private struct TelegramLoginWebView: UIViewRepresentable {
    let url: URL
    let onPayload: ([String: String]) -> Void
    let onLoadingChange: (Bool) -> Void
    let onFailure: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPayload: onPayload, onLoadingChange: onLoadingChange, onFailure: onFailure)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // A clean state every time, so a stale Telegram session can't leak in.
        config.websiteDataStore = .nonPersistent()

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.load(URLRequest(url: url))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onPayload: ([String: String]) -> Void
        private let onLoadingChange: (Bool) -> Void
        private let onFailure: () -> Void
        private var handled = false

        init(
            onPayload: @escaping ([String: String]) -> Void,
            onLoadingChange: @escaping (Bool) -> Void,
            onFailure: @escaping () -> Void
        ) {
            self.onPayload = onPayload
            self.onLoadingChange = onLoadingChange
            self.onFailure = onFailure
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            if url.scheme == "laxify", url.host == "auth", url.path.contains("telegram") {
                decisionHandler(.cancel)
                guard !handled else { return }
                handled = true

                var params: [String: String] = [:]
                if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
                    for item in items {
                        if let value = item.value { params[item.name] = value }
                    }
                }
                onPayload(params)
                return
            }

            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            onLoadingChange(true)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onLoadingChange(false)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            onFailure()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onFailure()
        }
    }
}
