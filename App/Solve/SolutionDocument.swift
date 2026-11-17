import AppKit
import PDFKit
import SwiftUI
import WebKit

/// The typed solution, rendered like Ask answers (Markdown + KaTeX) by App/Chat/solution.html.
struct SolutionWebView: NSViewRepresentable {
    let markdown: String
    let streaming: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        view.allowsMagnification = true
        context.coordinator.view = view
        if let page = Bundle.main.url(forResource: "solution", withExtension: "html") {
            view.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.show(markdown, streaming: streaming)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var view: WKWebView?
        private var ready = false
        private var shown: (String, Bool)?
        private var pending: (String, Bool)?
        private var throttle: Task<Void, Never>?

        func show(_ markdown: String, streaming: Bool) {
            pending = (markdown, streaming)
            guard ready, throttle == nil else { return }
            flush()
            // While streaming, redraw at most every 120 ms.
            throttle = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(120))
                self?.throttle = nil
                if let self, let pending = self.pending, pending.0 != self.shown?.0 || pending.1 != self.shown?.1 { self.flush() }
            }
        }

        private func flush() {
            guard let (markdown, streaming) = pending else { return }
            shown = pending
            view?.evaluateJavaScript("SOL.show(\(SolutionPDF.jsString(markdown)), false, \(streaming))")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            flush()
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            if action.navigationType == .linkActivated, let url = action.request.url {
                NSWorkspace.shared.open(url)
                return .cancel
            }
            return .allow
        }
    }
}

/// A PDF, scrolling through its pages.
struct PDFPreview: NSViewRepresentable {
    let data: Data

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .clear
        view.document = PDFDocument(data: data)
        context.coordinator.shown = data
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        // Only a new PDF replaces the document, so scrolling isn't reset on every update.
        guard context.coordinator.shown != data else { return }
        context.coordinator.shown = data
        view.document = PDFDocument(data: data)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var shown: Data?
    }
}

/// Makes an A4 PDF of the typed solution: renders it off screen, cuts it into pages between
/// paragraphs and places each slice inside the page margins.
@MainActor
enum SolutionPDF {
    static let page = CGSize(width: 595, height: 842)  // A4 in points
    static let margin: CGFloat = 54

    /// `header` rows (the sheet's name, Matrikelnummer, … from the student's details) go at the top
    /// as a two-column table, in place of the title; they are passed as plain text, never as Markdown.
    static func make(markdown: String, title: String, header: [(label: String, value: String)]) async throws -> Data {
        let width = page.width - 2 * margin
        let height = page.height - 2 * margin
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        let loader = Loader()
        view.navigationDelegate = loader
        guard let html = Bundle.main.url(forResource: "solution", withExtension: "html") else { throw CocoaError(.fileNoSuchFile) }
        view.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        try await loader.loaded()

        // The header's Sheet row already names the sheet; a title is added only without a header.
        let document = header.isEmpty ? "# \(title)\n\n" + markdown : markdown
        let rows = (try? JSONSerialization.data(withJSONObject: header.map { [$0.label, $0.value] })).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        let total = (try await view.evaluateJavaScript("SOL.show(\(jsString(document)), true, false, \(rows))") as? NSNumber)?.doubleValue ?? height
        view.frame.size.height = max(height, total)
        try await Task.sleep(for: .milliseconds(150))  // KaTeX fonts settle
        let cuts = ((try await view.evaluateJavaScript("SOL.breaks(\(Int(height)))") as? [NSNumber]) ?? [0, NSNumber(value: total)])
            .map { CGFloat($0.doubleValue) }

        let output = NSMutableData()
        var box = CGRect(origin: .zero, size: page)
        guard let consumer = CGDataConsumer(data: output),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown) }
        for (top, bottom) in zip(cuts, cuts.dropFirst()) where bottom > top {
            let configuration = WKPDFConfiguration()
            configuration.rect = CGRect(x: 0, y: top, width: width, height: bottom - top)
            let data = try await view.pdf(configuration: configuration)
            guard let provider = CGDataProvider(data: data as CFData),
                  let slice = CGPDFDocument(provider)?.page(at: 1) else { continue }
            let sliceBox = slice.getBoxRect(.mediaBox)
            context.beginPDFPage(nil)
            context.translateBy(x: margin, y: page.height - margin - sliceBox.height)
            context.drawPDFPage(slice)
            context.endPDFPage()
        }
        context.closePDF()
        return output as Data
    }

    /// A JavaScript string literal.
    static func jsString(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text])) ?? Data("[\"\"]".utf8)
        return String(decoding: data, as: UTF8.self).dropFirst().dropLast().description
    }

    private final class Loader: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, Error>?
        private var done = false

        func loaded() async throws {
            if done { return }
            try await withCheckedThrowingContinuation { self.continuation = $0 }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            done = true
            continuation?.resume()
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            done = true
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
