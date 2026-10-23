import AppKit
import ScreenCaptureKit

/// Debug aid: launched with `--snapshot`, the app photographs its own main window once per
/// screen, with real data, and quits. It uses ScreenCaptureKit's current-process content, which
/// covers only this app's windows and needs no screen-recording permission. The PNGs go to the
/// sandbox's temporary folder: ~/Library/Containers/app.jayansh.UniversityPortal/Data/tmp/snapshots
@MainActor
enum Snapshotter {
    static func run(model: AppModel) async {
        let folder = FileManager.default.temporaryDirectory.appending(path: "snapshots", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let log = folder.appending(path: "log.txt")
        var notes: [String] = []

        try? await Task.sleep(for: .seconds(4))  // first overview and window layout
        let courses = model.overview.courses.filter(\.active).map(\.id).prefix(2)
        let routes: [(String, Route)] = Route.sections.map { ($0.title.lowercased(), $0) }
            + courses.map { ("course-\($0)", Route.course($0)) }

        for (index, (name, route)) in routes.enumerated() {
            model.selection = route
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }) else { continue }
            window.setContentSize(NSSize(width: 1280, height: 800))
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .seconds(2))
            do {
                let png = try await capture(window)
                try png.write(to: folder.appending(path: "\(index)-\(name).png"))
            } catch {
                notes.append("\(name): \(error)")
            }
        }
        try? notes.joined(separator: "\n").write(to: log, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    private static func capture(_ window: NSWindow) async throws -> Data {
        let content = try await SCShareableContent.currentProcess
        guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        configuration.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return png
    }
}
