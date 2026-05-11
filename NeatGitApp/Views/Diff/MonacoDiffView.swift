import SwiftUI
import WebKit

struct MonacoDiffView: NSViewRepresentable {
    let payload: MonacoDiffPayload?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let userContentController = WKUserContentController()
        userContentController.add(context.coordinator, name: Coordinator.readyMessageHandlerName)
        configuration.userContentController = userContentController

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.attach(webView)
        context.coordinator.loadIfNeeded()
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.attach(webView)
        context.coordinator.update(payload: payload)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.readyMessageHandlerName)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let readyMessageHandlerName = "neatGitReady"

        private weak var webView: WKWebView?
        private var pendingPayload: MonacoDiffPayload?
        private var lastRenderedPayload: MonacoDiffPayload?
        private var isReady = false
        private var hasLoadedPage = false

        func attach(_ webView: WKWebView) {
            self.webView = webView
        }

        func loadIfNeeded() {
            guard !hasLoadedPage, let webView else { return }
            guard
                let resourceURL = Bundle.main.resourceURL,
                let serverURL = try? BundleStaticFileServer.shared.startIfNeeded(rootDirectoryURL: resourceURL),
                let indexURL = URL(string: "index.html", relativeTo: serverURL)
            else {
                return
            }

            hasLoadedPage = true
            webView.load(URLRequest(url: indexURL))
        }

        func update(payload: MonacoDiffPayload?) {
            pendingPayload = payload
            loadIfNeeded()
            renderIfPossible()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loadIfNeeded()
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == Self.readyMessageHandlerName else { return }
            isReady = true
            renderIfPossible()
        }

        private func renderIfPossible() {
            guard isReady, let webView else { return }
            guard pendingPayload != lastRenderedPayload else { return }

            guard let pendingPayload else { return }

            do {
                let data = try JSONEncoder().encode(pendingPayload)
                guard let json = String(data: data, encoding: .utf8) else { return }

                webView.evaluateJavaScript("window.neatGit && window.neatGit.setDiff(\(json));")
                lastRenderedPayload = pendingPayload
            } catch {
                return
            }
        }
    }
}
