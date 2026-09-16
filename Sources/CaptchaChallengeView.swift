import SwiftUI
import WebKit

struct CaptchaChallengeView: View {
    let url: URL
    let onCompleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = CaptchaBrowserSession()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Sicherheitsprüfung", systemImage: "person.badge.shield.checkmark")
                        .font(.headline)
                    Text("Bestätige die CAPTCHA-Prüfung selbst. VideoSave löst oder umgeht sie nicht.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()

                Divider()

                CaptchaWebView(url: url, session: session)
                    .ignoresSafeArea(edges: .bottom)
            }
            .navigationTitle("CAPTCHA")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Bestätigt") {
                        Task {
                            await session.copyCookiesToURLSession()
                            onCompleted()
                            dismiss()
                        }
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

@MainActor
final class CaptchaBrowserSession: ObservableObject {
    weak var webView: WKWebView?

    func copyCookiesToURLSession() async {
        guard let webView else { return }
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        for cookie in cookies {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }
}

private struct CaptchaWebView: UIViewRepresentable {
    let url: URL
    let session: CaptchaBrowserSession

    func makeCoordinator() -> Coordinator {
        Coordinator(originalURL: url)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        session.webView = webView

        var request = URLRequest(url: url)
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        webView.load(request)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) { }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let originalHost: String?

        init(originalURL: URL) {
            self.originalHost = originalURL.host?.lowercased()
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.targetFrame?.isMainFrame == true,
                  let destination = navigationAction.request.url,
                  let host = destination.host?.lowercased(),
                  let originalHost else {
                decisionHandler(.allow)
                return
            }

            let root = originalHost.hasPrefix("www.") ? String(originalHost.dropFirst(4)) : originalHost
            let sameSite = host == root || host == "www.\(root)" || host.hasSuffix(".\(root)")
            decisionHandler(sameSite ? .allow : .cancel)
        }
    }
}
