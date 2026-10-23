import AppKit
import SwiftUI
import UniversityKit
import WebKit

/// The Ask conversation rendered by App/Chat (StudyGPT's chat rendering: Markdown, KaTeX, code,
/// flashcards, artifacts, sources), hosted in a web view that only loads the bundled page.
struct ChatTranscript: NSViewRepresentable {
    let turns: [AskTurn]
    let model: String?
    let suggestions: [String]
    /// "#RRGGBB" of a course's colour.
    let courseColor: (Int64) -> String
    let onCite: (Excerpt) -> Void
    let onSuggest: (String) -> Void
    let onRegenerate: (UUID) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "up")
        configuration.preferences.isElementFullscreenEnabled = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")  // no white flash before the dark page paints
        view.allowsMagnification = true
        context.coordinator.view = view
        if let page = Bundle.main.url(forResource: "chat", withExtension: "html") {
            view.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.push()
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "up")
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        weak var view: WKWebView?
        var parent: ChatTranscript?
        private var ready = false
        private var lastSent = ""
        private var lastPush = Date.distantPast
        private var pending: Task<Void, Never>?
        private var lastTurnCount = 0

        /// Sends the state to the page; while an answer streams, at most every 80 ms.
        func push() {
            guard ready, let parent else { return }
            let streaming = parent.turns.last.map { $0.phase == .searching || $0.phase == .writing } ?? false
            let wait = 0.08 - Date.now.timeIntervalSince(lastPush)
            if streaming, wait > 0 {
                guard pending == nil else { return }
                pending = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(wait))
                    self?.pending = nil
                    self?.push()
                }
                return
            }
            let json = Self.state(parent, scrollToEnd: parent.turns.count != lastTurnCount)
            guard json != lastSent else { return }
            lastSent = json
            lastPush = .now
            lastTurnCount = parent.turns.count
            view?.evaluateJavaScript("UP.setState(\(json))")
        }

        static func state(_ transcript: ChatTranscript, scrollToEnd: Bool) -> String {
            let lastDone = transcript.turns.lastIndex { $0.phase == .done }
            let turns: [[String: Any]] = transcript.turns.enumerated().map { index, turn in
                let phase: String, error: String?
                switch turn.phase {
                case .searching: (phase, error) = ("searching", nil)
                case .writing: (phase, error) = ("writing", nil)
                case .done: (phase, error) = ("done", nil)
                case .failed(let message): (phase, error) = ("failed", message)
                }
                return [
                    "id": turn.id.uuidString,
                    "question": turn.question,
                    "answer": turn.answer,
                    "phase": phase,
                    "error": error as Any,
                    "manageUsage": error?.contains("usage limit") == true,
                    "model": transcript.model as Any,
                    "cited": turn.cited,
                    "canRegenerate": index == lastDone && index == transcript.turns.count - 1,
                    "excerpts": turn.excerpts.map { excerpt in
                        [
                            "number": excerpt.number, "itemId": excerpt.itemId, "title": excerpt.title,
                            "course": excerpt.course, "page": excerpt.page, "text": excerpt.text,
                            "color": transcript.courseColor(excerpt.courseId),
                        ] as [String: Any]
                    },
                ]
            }
            let state: [String: Any] = [
                "turns": turns,
                "scrollToEnd": scrollToEnd,
                "empty": [
                    "title": "Ask anything about your lecture materials",
                    "text": "Answers come from your own PDFs and cite the page; click a citation to open it. Math, code, tables, flashcards (“make flashcards for …”) and visualizations render inline.",
                    "suggestions": transcript.suggestions,
                ],
            ]
            let data = (try? JSONSerialization.data(withJSONObject: state)) ?? Data("{}".utf8)
            return String(decoding: data, as: UTF8.self)
        }

        // MARK: Messages from the page

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                ready = true
                lastSent = ""
                push()
            case "cite":
                guard let turnId = (body["turn"] as? String).flatMap(UUID.init), let number = body["number"] as? Int,
                      let excerpt = parent?.turns.first(where: { $0.id == turnId })?.excerpts.first(where: { $0.number == number }) else { return }
                parent?.onCite(excerpt)
            case "copy":
                guard let text = body["text"] as? String else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            case "open":
                guard let url = (body["url"] as? String).flatMap(URL.init(string:)),
                      ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return }
                NSWorkspace.shared.open(url)
            case "suggest":
                if let text = body["text"] as? String { parent?.onSuggest(text) }
            case "regenerate":
                if let id = (body["turn"] as? String).flatMap(UUID.init) { parent?.onRegenerate(id) }
            default:
                break
            }
        }

        // MARK: Navigation: the page itself only; links go to the browser

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url else { return .cancel }
            // The bundled page and the sandboxed artifact frames (about:srcdoc) may load.
            if url.isFileURL || url.scheme == "about" { return .allow }
            if action.targetFrame?.isMainFrame == false { return .allow }  // an artifact's own resources
            if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
            return .cancel
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
            return nil
        }
    }
}

extension Color {
    /// "#RRGGBB", for the web page.
    var hex: String {
        let color = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        return String(format: "#%02X%02X%02X", Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255))
    }
}
