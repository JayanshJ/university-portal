import AppKit
import SwiftUI
import ScreenCaptureKit
import UniversityKit

/// Debug aid: launched with `--snapshot`, the app photographs its own main window once per
/// screen and appearance, with real data, and quits. It uses ScreenCaptureKit's current-process content, which
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

        // Every screen in dark and then light appearance.
        for (appearance, suffix) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            NSApp.appearance = NSAppearance(named: appearance)
            for (index, (name, route)) in routes.enumerated() {
                model.selection = route
                guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }) else { continue }
                window.setContentSize(NSSize(width: 1280, height: 800))
                window.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .seconds(2))
                do {
                    let png = try await capture(window)
                    try png.write(to: folder.appending(path: "\(index)-\(name)-\(suffix).png"))
                } catch {
                    notes.append("\(name) \(suffix): \(error)")
                }
            }

            // The hand-in sheet for the first assignment, with sample data (no Moodle calls), in its
            // own window: screen capture can't take a sheet on its own.
            if let item = model.overview.openDeadlines.first(where: { model.submitTarget($0) != nil }),
               let target = model.submitTarget(item) {
                let service = MoodleSubmissions(client: MoodleClient(token: "demo", transport: DemoMoodle(cmid: target.cmid)))
                let sheet = NSWindow(contentViewController: NSHostingController(
                    rootView: SubmissionView(model: SubmissionModel(cmid: target.cmid, service: service), item: item).environment(model)))
                sheet.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .seconds(3))
                do {
                    try await capture(sheet).write(to: folder.appending(path: "9-submit-\(suffix).png"))
                } catch {
                    notes.append("submit \(suffix): \(error)")
                }
                sheet.close()
            }
        }
        try? notes.joined(separator: "\n").write(to: log, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    /// Sample answers for the hand-in sheet: a PDF-only assignment with drafts, a statement and one file on Moodle.
    private struct DemoMoodle: HTTPTransport {
        let cmid: Int

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            let json = if body.contains("core_course_get_course_module") {
                #"{"cm":{"course":1,"instance":55,"modname":"assign"}}"#
            } else if body.contains("mod_assign_get_assignments") {
                #"{"courses":[{"assignments":[{"id":55,"cmid":\#(cmid),"name":"Exercise Sheet 1","submissiondrafts":1,"requiresubmissionstatement":1,"submissionstatement":"This submission is my own work, except where I have acknowledged the work of others.","intro":"<p>Solve tasks 1–4 and hand in one PDF with your answers. Code goes in a ZIP.</p>","introattachments":[{"filename":"sheet1.pdf","fileurl":"x","filesize":182000}],"configs":[{"plugin":"file","subtype":"assignsubmission","name":"enabled","value":"1"},{"plugin":"file","subtype":"assignsubmission","name":"maxfilesubmissions","value":"2"},{"plugin":"file","subtype":"assignsubmission","name":"maxsubmissionsizebytes","value":"20971520"},{"plugin":"file","subtype":"assignsubmission","name":"filetypeslist","value":".pdf,.zip"}]}]}]}"#
            } else {
                #"{"lastattempt":{"submission":{"status":"draft","timemodified":1792800000,"plugins":[{"type":"file","fileareas":[{"files":[{"filename":"answers.pdf","fileurl":"x","filesize":348000}]}]}]},"canedit":true,"cansubmit":true}}"#
            }
            return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
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
