import AppKit
import Foundation
import GRDB
import SwiftUI
import UniversityKit

/// Debug aid: launched with `--solve-check`, runs the Solve panel's two renderers without Moodle or
/// ChatGPT (Math Writer through the Application Scripts helper, and the typed PDF), writes the
/// results to ~/Library/Containers/app.jayansh.UniversityPortal/Data/tmp/solve-check, and quits.
@MainActor
enum SolveCheck {
    /// The sheet Solve would pick for each open deadline, with the runners-up.
    static func matches(_ overview: PortalOverview) {
        for deadline in overview.openDeadlines.prefix(25) {
            let candidates = SheetFinder.candidates(assignment: deadline.title, deadline: deadline, overview: overview)
            let best = SheetFinder.best(candidates)
            print("MATCH \(deadline.course) | \(deadline.title) → \(best?.name ?? "(ask)")")
            for candidate in candidates.prefix(3) { print("      \(candidate.score)  \(candidate.name)  [\(candidate.item.course)]") }
        }
    }

    /// Per course: material files, how many are indexed, indexed pages and characters, other text items.
    static func indexStats(_ database: UniDatabase) async {
        let lines = (try? await database.writer.read { db -> [String] in
            try Row.fetchAll(db, sql: """
                SELECT c.id AS id, c.short_name AS course, c.active AS active,
                  (SELECT COUNT(*) FROM uni_item i JOIN uni_file f ON f.item_id = i.id WHERE i.course_id = c.id AND i.kind = 'material' AND i.deleted_at IS NULL) AS files,
                  (SELECT COUNT(*) FROM uni_item i JOIN uni_file f ON f.item_id = i.id WHERE i.course_id = c.id AND i.kind = 'material' AND i.deleted_at IS NULL AND lower(f.filename) LIKE '%.pdf') AS pdfs,
                  (SELECT COUNT(*) FROM uni_index x JOIN uni_item i ON i.id = x.item_id WHERE i.course_id = c.id AND x.error IS NULL) AS indexed,
                  (SELECT COALESCE(SUM(x.pages), 0) FROM uni_index x JOIN uni_item i ON i.id = x.item_id WHERE i.course_id = c.id AND x.error IS NULL) AS pages,
                  (SELECT COALESCE(SUM(length(p.text)), 0) FROM uni_page p JOIN uni_item i ON i.id = p.item_id WHERE i.course_id = c.id) AS chars,
                  (SELECT COUNT(*) FROM uni_item i WHERE i.course_id = c.id AND i.kind IN ('announcement', 'discussion', 'note') AND i.deleted_at IS NULL) AS texts
                FROM uni_course c ORDER BY c.active DESC, c.short_name
                """).map { row in
            let id: Int64 = row["id"], course: String = row["course"], active: Bool = row["active"]
            let files: Int = row["files"], pdfs: Int = row["pdfs"], indexed: Int = row["indexed"], pages: Int = row["pages"]
            let chars: Int = row["chars"], texts: Int = row["texts"]
            return "STATS \(active ? "active" : "      ") \(course) [\(id)] | files \(files), pdf \(pdfs), indexed \(indexed), pages \(pages), chars \(chars), notes/posts \(texts)"
            }
        }) ?? []
        lines.forEach { print($0) }
    }

    /// `--solve-check memory <courseId>`: indexes the course and its related courses, builds their
    /// memory with the real ChatGPT sign-in, prints a MEMORY line and the start of the memory text, and quits.
    static func memory(ask: AskModel, courseId: Int64, overview: PortalOverview) async {
        defer {
            fflush(stdout)
            NSApp.terminate(nil)
        }
        guard let course = overview.courses.first(where: { $0.id == courseId }) else {
            print("MEMORY no course \(courseId)")
            return
        }
        let courses = overview.courses.map { (id: $0.id, name: $0.shortName + " " + $0.fullName, active: $0.active) }
        let ids = CourseLinks.related(courseId: courseId, courseName: course.shortName + " " + course.fullName, courses: courses)
        let list = ids.map(String.init).joined(separator: ",")
        let (pdfs, indexed) = (try? await ask.database.writer.read { db -> (Int, Int) in
            let pdfs = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM uni_item i JOIN uni_file f ON f.item_id = i.id
                WHERE i.kind = 'material' AND i.deleted_at IS NULL AND lower(f.filename) LIKE '%.pdf' AND i.course_id IN (\(list))
                """) ?? 0
            let indexed = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM uni_index x JOIN uni_item i ON i.id = x.item_id WHERE x.error IS NULL AND i.course_id IN (\(list))
                """) ?? 0
            return (pdfs, indexed)
        }) ?? (0, 0)
        print("MEMORY course \(course.shortName) related=\(ids.map { id in overview.courses.first { $0.id == id }?.shortName ?? String(id) }) pdfs=\(pdfs) indexed=\(indexed)")
        guard pdfs <= 15 || CommandLine.arguments.contains("--force") else {
            print("MEMORY stopped: more than 15 PDFs (pass --force to run anyway)")
            return
        }
        await ask.refreshAccount()
        guard ask.account?.canUsePlan == true, let memory = ask.memory() else {
            print("MEMORY not signed in to ChatGPT (account \(ask.account == nil ? "none" : "without plan"), model \(ask.model ?? "none"))")
            return
        }
        let started = Date()
        let index = await ask.indexCourses(ids)
        print("MEMORY indexed done=\(index.done) total=\(index.total) failed=\(index.failed)")
        let progress = await memory.run(courseIds: ids, memoryCourseId: courseId) { progress in
            if let current = progress.current { print("  \(progress.done)/\(progress.total) done, reading \(current)") }
        }
        let seconds = Int(Date().timeIntervalSince(started))
        guard let document = try? memory.document(memoryCourseId: courseId, courseIds: ids) else {
            print("MEMORY document failed")
            return
        }
        let text = CourseMemory.text(document, keeping: [])
        print("MEMORY files=\(document.files.count + document.unread.count) digested=\(progress.total - progress.failed.count) failed=\(progress.failed.count) chars=\(text.count) seconds=\(seconds)")
        if !progress.failed.isEmpty { print("MEMORY failed: \(progress.failed)") }
        for file in document.unread { print("MEMORY unread: \(file.title) — \(file.reason)") }
        print(String(text.prefix(1500)))
        for file in [document.files.first { $0.title.hasPrefix("Lecture") }, document.files.first { $0.title.hasPrefix("Exercise") }].compactMap({ $0 }) {
            print("DIGEST \(file.title)\n" + String(file.digest.prefix(600)))
        }
    }

    static func run(ask: AskModel) async {
        let folder = FileManager.default.temporaryDirectory.appending(path: "solve-check", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var rendering: Handwriter.Rendering?
        var log: [String] = ["handwriting set up: \(Handwriter.isSetUp)", "markup guide: \(Handwriter.markupGuide.count) chars"]
        if Handwriter.isSetUp {
            do {
                let bad = try? await Handwriter.render("x^2 [F]1[/F]", strict: true)
                log.append("strict bad markup rendered: \(bad != nil)")
                let rendered = try await Handwriter.render(demoMarkup, strict: true)
                rendering = rendered
                log.append("handwritten: \(rendered.pages.count) page(s), \((try? Data(contentsOf: rendered.pdf).count) ?? 0) bytes, dropped \(rendered.dropped)")
            } catch {
                log.append("handwritten FAILED: \(error)")
            }
        }

        do {
            var markdown = "## Aufgabe 1\n\n(a) Es gilt $\\frac{1}{3} + \\frac{1}{6} = \\frac{1}{2}$, denn\n\n$$\\int_0^1 x^2\\,dx = \\frac{1}{3}.$$\n\n$$\\boxed{x = 2}$$\n\n"
            for n in 2...8 { markdown += "## Aufgabe \(n)\n\nSei $A = \\begin{pmatrix}1 & 2\\\\ 3 & 4\\end{pmatrix}$. Dann ist $\\det A = -2 \\neq 0$, also ist $A$ invertierbar, und $$A^{-1} = \\frac{1}{-2}\\begin{pmatrix}4 & -2\\\\ -3 & 1\\end{pmatrix}.$$\n\n" }
            let data = try await SolutionPDF.make(markdown: markdown, title: "Übungsblatt 4")
            try data.write(to: folder.appending(path: "typed.pdf"))
            log.append("typed: \(data.count) bytes")
        } catch {
            log.append("typed FAILED: \(error)")
        }
        try? log.joined(separator: "\n").write(to: folder.appending(path: "log.txt"), atomically: true, encoding: .utf8)
        print(log.joined(separator: "\n"))
        await screenshots(ask: ask, rendering: rendering)
        fflush(stdout)
        NSApp.terminate(nil)
    }

    /// The panel in both formats, printed as "SHOT:<name>:<base64 PNG>" lines.
    private static func screenshots(ask: AskModel, rendering: Handwriter.Rendering?) async {
        ask.showDemo(courseId: nil)
        let service = MoodleSubmissions(client: MoodleClient(token: "demo", transport: Snapshotter.DemoMoodle(cmid: 1)))
        guard let rules = try? await service.rules(cmid: 1) else { print("no demo rules"); return }
        let model = SolveModel(assignment: rules, service: service, ask: ask, database: ask.database, deadline: nil,
                               courseIds: [], courseName: "", courseShort: "", candidates: [],
                               openMaterial: { _ in throw CocoaError(.fileNoSuchFile) })
        model.showDemo(request: "Show the substitution step in 1(b) in more detail",
                       note: "I expanded the substitution in 1(b) into two steps.",
                       solution: demoSolution, rendering: rendering)
        let window = NSWindow(contentViewController: NSHostingController(rootView:
            SolvePanel(model: model, ask: ask, acceptsFiles: true, acceptsText: false,
                       attach: { _, _ in }, useAsText: { _ in }, close: {}).frame(width: 520, height: 720)))
        window.makeKeyAndOrderFront(nil)
        for (appearance, format) in [(NSAppearance.Name.darkAqua, SolveModel.Format.handwritten), (.darkAqua, .typed), (.aqua, .handwritten), (.aqua, .typed)] {
            NSApp.appearance = NSAppearance(named: appearance)
            model.format = format
            try? await Task.sleep(for: .seconds(2))
            if let png = try? await Snapshotter.capture(window) {
                print("SHOT:\(format.rawValue)-\(appearance == .aqua ? "light" : "dark"):" + png.base64EncodedString())
            }
        }
    }

    static let demoMarkup = """
        ~~Aufgabe 1~~

        (a) Es gilt [F]1|3[/F] + [F]1|6[/F] = [F]2|6[/F] + [F]1|6[/F] = [F]1|2[/F].

        (b) Mit u = x² ist du = 2x dx, also

         [I]0|1[/I] 2x e[U]x²[/U] dx = [I]0|1[/I] e[U]u[/U] du = e − 1.

        [B]e − 1[/B]
        """

    static let demoSolution = """
        ## Aufgabe 1

        **(a)** Es gilt $\\frac{1}{3} + \\frac{1}{6} = \\frac{2}{6} + \\frac{1}{6} = \\frac{1}{2}$.

        **(b)** Mit der Substitution $u = x^2$ ist $du = 2x\\,dx$, und die Grenzen bleiben $0$ und $1$:

        $$\\int_0^1 2x\\,e^{x^2}\\,dx = \\int_0^1 e^{u}\\,du = e - 1.$$

        $$\\boxed{e - 1}$$
        """
}
