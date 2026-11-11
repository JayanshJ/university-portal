import AppKit
import UniversityKit
import WebKit

/// A fresh sign-in session that follows the site's SSO redirects and catches Moodle's callback.
@MainActor
final class MoodleSignIn: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    enum SignInError: LocalizedError {
        case cancelled
        var errorDescription: String? { "Sign-in cancelled." }
    }

    private var window: NSWindow?
    private var webView: WKWebView?
    private var progress: NSProgressIndicator?
    private var status: NSTextField?
    private var continuation: CheckedContinuation<URL, Error>?

    func callbackURL(for url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let webView = WKWebView(frame: .zero, configuration: configuration)
            webView.navigationDelegate = self
            webView.uiDelegate = self

            let progress = NSProgressIndicator()
            progress.style = .spinning
            progress.controlSize = .small
            progress.isDisplayedWhenStopped = false
            let status = NSTextField(labelWithString: "Loading sign-in page…")
            status.lineBreakMode = .byTruncatingMiddle
            let header = NSStackView(views: [progress, status])
            header.orientation = .horizontal
            header.spacing = 8
            header.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
            let content = NSView()
            header.translatesAutoresizingMaskIntoConstraints = false
            webView.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(header)
            content.addSubview(webView)
            NSLayoutConstraint.activate([
                header.topAnchor.constraint(equalTo: content.topAnchor),
                header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                webView.topAnchor.constraint(equalTo: header.bottomAnchor),
                webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                webView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 720),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Moodle Sign In"
            window.contentView = content
            window.delegate = self
            window.center()
            self.window = window
            self.webView = webView
            self.progress = progress
            self.status = status
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            webView.load(URLRequest(url: url))
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        switch MoodleSignInNavigation.destination(for: url) {
        case .callback:
            decisionHandler(.cancel)
            finish(.success(url))
        case .web:
            // A new-window request must stay in the same cookie session.
            if action.targetFrame == nil {
                decisionHandler(.cancel)
                webView.load(action.request)
            } else {
                decisionHandler(.allow)
            }
        case .unsupported:
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil, let url = action.request.url,
           MoodleSignInNavigation.destination(for: url) == .web {
            webView.load(action.request)
        }
        return nil
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        progress?.startAnimation(nil)
        status?.stringValue = "Loading sign-in page…"
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        let host = webView.url?.host ?? ""
        window?.title = "Moodle Sign In — \(host)"
        status?.stringValue = host
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        progress?.stopAnimation(nil)
        status?.stringValue = webView.url?.host ?? ""
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        finish(.failure(error))
    }

    func windowWillClose(_ notification: Notification) { finish(.failure(SignInError.cancelled)) }

    private func finish(_ result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        window?.delegate = nil
        window?.close()
        window = nil
        webView = nil
        progress = nil
        status = nil
        continuation.resume(with: result)
    }
}
