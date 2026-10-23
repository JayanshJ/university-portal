import AppKit
import CoreImage
import PDFKit
import SwiftUI
import UniversityKit

/// Drives a `PDFView` from SwiftUI buttons and reports its page.
@MainActor @Observable
final class PDFController {
    fileprivate weak var view: PDFView?
    var pageIndex = 0
    var pageCount = 0

    func zoomIn() { view?.zoomIn(nil) }
    func zoomOut() { view?.zoomOut(nil) }
    func fit() { view?.autoScales = true }
}

/// PDFKit, not a web view: native rendering, text selection, and fast loading from disk.
struct PDFKitView: NSViewRepresentable {
    let url: URL
    let darkPages: Bool
    let controller: PDFController

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = NSColor(white: 0.08, alpha: 1)
        view.wantsLayer = true
        controller.view = view
        context.coordinator.observe(view)
        load(into: view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url { load(into: view) }
        applyDarkPages(to: view)
    }

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    private func load(into view: PDFView) {
        view.document = PDFDocument(url: url)
        controller.pageCount = view.document?.pageCount ?? 0
        controller.pageIndex = 0
        applyDarkPages(to: view)
    }

    /// Inverts the pages for reading slides at night; the hue turn keeps colours recognisable.
    private func applyDarkPages(to view: PDFView) {
        guard darkPages else {
            view.contentFilters = []
            return
        }
        let invert = CIFilter(name: "CIColorInvert")!
        let hue = CIFilter(name: "CIHueAdjust")!
        hue.setValue(Float.pi, forKey: kCIInputAngleKey)
        view.contentFilters = [invert, hue]
    }

    @MainActor
    final class Coordinator: NSObject {
        let controller: PDFController
        private var token: NSObjectProtocol?

        init(controller: PDFController) { self.controller = controller }

        func observe(_ view: PDFView) {
            token = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let page = view.currentPage, let document = view.document else { return }
                    self.controller.pageIndex = document.index(for: page)
                    self.controller.pageCount = document.pageCount
                }
            }
        }
    }
}

/// A file viewer with the minimal toolbar from the plan: page, zoom, dark pages, Preview, Finder, original.
struct FileViewer: View {
    @Environment(AppModel.self) private var model
    let item: PortalOverview.ItemRow
    @State private var fileURL: URL?
    @State private var error: String?
    @State private var controller = PDFController()

    private var isPDF: Bool {
        (item.filename ?? item.title).lowercased().hasSuffix(".pdf")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.headline).lineLimit(1)
                    Text([item.course, item.section].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if isPDF, fileURL != nil {
                    Text("\(controller.pageIndex + 1) / \(controller.pageCount)")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    ControlGroup {
                        Button { controller.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                            .help("Zoom out")
                        Button { controller.fit() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                            .help("Fit width")
                        Button { controller.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                            .help("Zoom in")
                    }
                    .fixedSize()
                    Toggle(isOn: Binding(get: { model.overview.pdfDarkPages }, set: { model.setDarkPages($0) })) {
                        Image(systemName: "moon")
                    }
                    .toggleStyle(.button)
                    .help("Dark pages")
                }
                Menu {
                    if let fileURL {
                        Button("Open in Preview") { model.openInDefaultApp(fileURL) }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }
                    }
                    Button("Open Original Page") { model.openLink(item) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()

            Group {
                if let error {
                    ContentUnavailableView("Could not open the file", systemImage: "exclamationmark.triangle",
                                           description: Text(error))
                } else if let fileURL, isPDF {
                    PDFKitView(url: fileURL, darkPages: model.overview.pdfDarkPages, controller: controller)
                } else if let fileURL {
                    ContentUnavailableView {
                        Label(item.filename ?? item.title, systemImage: "doc")
                    } description: {
                        Text("This file type opens in its own app.")
                    } actions: {
                        Button("Open") { model.openInDefaultApp(fileURL) }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }
                    }
                } else {
                    ProgressView(item.isCached ? "Opening…" : "Downloading…")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: item.id) {
            fileURL = nil
            error = nil
            do {
                fileURL = try await model.localFile(item)
            } catch {
                self.error = model.describeError(error)
            }
        }
    }
}

/// A material in its own window (double-click in Materials).
struct ViewerWindow: View {
    @Environment(AppModel.self) private var model
    let itemId: Int64?

    var body: some View {
        Group {
            if let item = model.overview.materials.first(where: { $0.id == itemId }) {
                FileViewer(item: item)
            } else {
                ContentUnavailableView("File not available", systemImage: "doc")
            }
        }
        .frame(minWidth: 600, minHeight: 500)
    }
}
