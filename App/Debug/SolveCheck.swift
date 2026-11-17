#if DEBUG
import AppKit
import Foundation
import GRDB
import PDFKit
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
        // A synthetic handwriting (a font, photographed and read back), never the student's own.
        if let library = TemplateCheck.syntheticLibrary(named: "solve-check-glyphs") { Handwriter.library = library }
        var log: [String] = ["handwriting library: \(Handwriter.library.lastPathComponent), set up: \(Handwriter.isSetUp)",
                             "markup guide: \(Handwriter.markupGuide.count) chars"]
        if Handwriter.isSetUp {
            do {
                let bad = try? await Handwriter.render("x^2 [F]1[/F]", strict: true)
                log.append("strict bad markup rendered: \(bad != nil)")
                let rendered = try await Handwriter.render(demoMarkup, strict: true)
                log.append("handwritten: \(rendered.pages.count) page(s), \((try? Data(contentsOf: rendered.pdf).count) ?? 0) bytes, dropped \(rendered.dropped)")
            } catch {
                log.append("handwritten FAILED: \(error)")
            }
        }

        do {
            var markdown = "## Aufgabe 1\n\n(a) Es gilt $\\frac{1}{3} + \\frac{1}{6} = \\frac{1}{2}$, denn\n\n$$\\int_0^1 x^2\\,dx = \\frac{1}{3}.$$\n\n$$\\boxed{x = 2}$$\n\n"
            for n in 2...8 { markdown += "## Aufgabe \(n)\n\nSei $A = \\begin{pmatrix}1 & 2\\\\ 3 & 4\\end{pmatrix}$. Dann ist $\\det A = -2 \\neq 0$, also ist $A$ invertierbar, und $$A^{-1} = \\frac{1}{-2}\\begin{pmatrix}4 & -2\\\\ -3 & 1\\end{pmatrix}.$$\n\n" }
            let data = try await SolutionPDF.make(markdown: markdown, title: "Übungsblatt 4", header: [("Name", "Ada Lovelace"), ("Matrikelnummer", "2571234")])
            try data.write(to: folder.appending(path: "typed.pdf"))
            log.append("typed: \(data.count) bytes, \(PDFDocument(data: data)?.pageCount ?? 0) page(s)")
        } catch {
            log.append("typed FAILED: \(error)")
        }
        try? log.joined(separator: "\n").write(to: folder.appending(path: "log.txt"), atomically: true, encoding: .utf8)
        print(log.joined(separator: "\n"))
        await screenshots(ask: ask)
        fflush(stdout)
        NSApp.terminate(nil)
    }

    /// German rules and made-up details for the demo (never the database's real ones).
    static let demoRules = SubmissionRules(header: [.name, .matrikelnr, .group], filename: "Blatt{sheet}_{lastname}_{matrikelnr}.pdf",
                                           quote: "Bitte geben Sie Ihren Namen, Ihre Matrikelnummer und Ihre Gruppe auf der Abgabe an.")
    static let demoStudent = StudentDetails(name: "Ada Lovelace", matrikelnr: "2571234", email: "ada@example.org")
    static let demoCourse = CourseDetails(group: "Gruppe 3")

    /// The panel in both formats and the PDFs it makes, printed as "SHOT:<name>:<base64 PNG>" lines,
    /// plus whether "Add to Submission" hands in exactly the previewed bytes ("PDFSAME").
    private static func screenshots(ask: AskModel) async {
        ask.showDemo(courseId: nil)
        let service = MoodleSubmissions(client: MoodleClient(token: "demo", transport: Snapshotter.DemoMoodle(cmid: 1)))
        guard let rules = try? await service.rules(cmid: 1) else { print("no demo rules"); return }
        let model = SolveModel(assignment: rules, service: service, ask: ask, database: ask.database, deadline: nil,
                               courseIds: [], courseName: "Analysis I", courseShort: "ANA", candidates: [],
                               openMaterial: { _ in throw CocoaError(.fileNoSuchFile) })
        model.format = .typed
        model.showDemo(request: "Show the substitution step in 1(b) in more detail",
                       note: "I expanded the substitution in 1(b) into two steps.",
                       solution: demoSolution, markup: demoMarkup, rules: demoRules, student: demoStudent, course: demoCourse)
        var attached: (name: String, data: Data)?
        let window = NSWindow(contentViewController: NSHostingController(rootView:
            SolvePanel(model: model, ask: ask, acceptsFiles: true, acceptsText: false,
                       attach: { attached = ($0, $1) }, useAsText: { _ in }, openMemory: { _ in }, close: {})
                .frame(width: 520, height: 720)))
        window.makeKeyAndOrderFront(nil)
        print("FILENAME \(model.suggestedFilename)")
        print("HEADER " + model.headerRows.map { "\($0.label): \($0.value)" }.joined(separator: " | "))

        /// Waits for the format's PDF, prints its pages, and checks what Add to Submission would attach.
        func check(_ format: SolveModel.Format, shot: String) async -> Data? {
            model.format = format
            for _ in 0..<300 where model.output[format]?.revision != model.revision {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let cached = model.output[format]?.data else {
                print("PDF \(format.rawValue) not ready: \(model.outputError ?? "\(model.handwriting)")")
                return nil
            }
            if let attachment = try? await model.attachment() { attached = (attachment.filename, attachment.data) }
            print("PDFSAME \(shot) \(attached?.data == cached && attached?.data == model.output[format]?.data) (\(cached.count) bytes, \(attached?.name ?? "-"))")
            if let document = PDFDocument(data: cached) {
                print("PDF \(shot): \(document.pageCount) page(s), page 1 text: \(document.page(at: 0)?.string?.prefix(80).replacingOccurrences(of: "\n", with: " ") ?? "(none)")")
                for index in 0..<min(document.pageCount, 2) {
                    if let png = pagePNG(document.page(at: index)) { print("SHOT:pdf-\(shot)-p\(index + 1):" + png.base64EncodedString()) }
                }
            }
            return cached
        }

        let typed = await check(.typed, shot: "typed")
        await panelShot(window, "typed")
        _ = await check(.handwritten, shot: "handwritten")
        if case .ready(let rendering, _) = model.handwriting { print("HANDWRITTEN dropped: \(rendering.dropped)") }
        await panelShot(window, "handwritten")

        // A header value the handwriting has no glyph for ("&"): typed onto page 1 instead.
        model.overrideHeader(.name, value: "Ada Lovelace & Co")
        print("INVALIDATED \(model.output.isEmpty)")
        _ = await check(.handwritten, shot: "handwritten-stamped")
        let typedAgain = await check(.typed, shot: "typed-override")
        print("TYPED CHANGED \(typed != nil && typedAgain != nil && typed != typedAgain)")
        print("FILENAME after override \(model.suggestedFilename)")

        await stateShots(model: model, ask: ask, window: window)
    }

    /// The states before and around a solution: memory progress, the details form, the rules row
    /// expanded, the source chips and the not-read banner. Made-up values; nothing is saved.
    private static func stateShots(model: SolveModel, ask: AskModel, window: NSWindow) async {
        model.format = .typed
        model.showDemoState(phase: .memory(CourseMemory.Progress(done: 7, total: 22, current: "Vorlesung 05 – Substitution und partielle Integration.pdf")))
        await panelShot(window, "memory")

        // Rules that need partners; the student has only a name so far.
        let partnerRules = SubmissionRules(header: [.name, .matrikelnr, .group, .partnerNames, .partnerMatrikelnr],
                                           filename: demoRules.filename, quote: demoRules.quote)
        let incomplete = StudentDetails(name: "Ada Lovelace")
        model.showDemo(request: "Show the substitution step in 1(b) in more detail",
                       note: "I expanded the substitution in 1(b) into two steps.",
                       solution: demoSolution, markup: demoMarkup, rules: partnerRules, student: incomplete, course: CourseDetails())
        let missing = partnerRules.missing(student: incomplete, course: CourseDetails(), sheet: model.sheetNumber)
        print("DETAILS missing \(missing.map(\.rawValue))")
        model.showDemoState(phase: .needsDetails(missing))
        await panelShot(window, "needs-details")
        // A field the model wrongly asked for: "Not Needed" takes it out of the form, header and file name.
        model.setNeeded(.partnerMatrikelnr, false)
        print("DROPPED missing \(model.missingDetails().map(\.rawValue)) | header " + model.headerRows.map(\.label).joined(separator: " | "))
        await panelShot(window, "needs-details-not-needed")
        model.setNeeded(.partnerMatrikelnr, true)

        // Back to complete details, with sources and files that couldn't be read.
        model.showDemo(request: "Show the substitution step in 1(b) in more detail",
                       note: "I expanded the substitution in 1(b) into two steps.",
                       solution: demoSolution, markup: demoMarkup, rules: demoRules, student: demoStudent, course: demoCourse)
        let excerpt = Excerpt(number: 1, itemId: -1, courseId: 0, title: "Vorlesung 05 – Substitution.pdf", course: "Analysis I", page: 14,
                              text: "Substitutionsregel: ∫ f(g(x)) g'(x) dx = ∫ f(u) du.")
        model.showDemoState(phase: .idle,
                            unread: [(title: "Blatt 2 Lösungen (Scan).pdf", reason: "No text in the PDF (a scan)."),
                                     (title: "Formelsammlung.pdf", reason: "Couldn't download it.")],
                            sources: [.excerpt(1), .memory("Course overview"), .excerpt(9)], excerpts: [excerpt])
        /// The panel in its own window with one section expanded (one at a time, as in the app).
        func expandedWindow(rules: Bool, unread: Bool) -> NSWindow {
            let window = NSWindow(contentViewController: NSHostingController(rootView:
                SolvePanel(model: model, ask: ask, acceptsFiles: true, acceptsText: false,
                           attach: { _, _ in }, useAsText: { _ in }, openMemory: { _ in }, close: {}, showsRules: rules, showsUnread: unread)
                    .frame(width: 520, height: 720)))
            window.makeKeyAndOrderFront(nil)
            return window
        }
        for _ in 0..<300 where model.output[.typed]?.revision != model.revision {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let rulesWindow = expandedWindow(rules: true, unread: false)
        await panelShot(rulesWindow, "rules-expanded")
        // The group marked "Not needed for this sheet" in the rules row.
        model.setNeeded(.group, false)
        print("DROPPED group: header " + model.headerRows.map(\.label).joined(separator: " | ") + " → \(model.suggestedFilename)")
        await panelShot(rulesWindow, "rules-expanded-not-needed")
        model.setNeeded(.group, true)
        rulesWindow.orderOut(nil)
        let unreadWindow = expandedWindow(rules: false, unread: true)
        await panelShot(unreadWindow, "unread-expanded")
        unreadWindow.orderOut(nil)
        window.makeKeyAndOrderFront(nil)
        await panelShot(window, "sources-collapsed")

        // Handing in alone: the partner rows leave the header and the details form.
        let aloneCourse = CourseDetails(group: "Gruppe 3", alone: true)
        print("ALONE missing \(partnerRules.missing(student: demoStudent, course: aloneCourse, sheet: 1).map(\.rawValue))")
        print("ALONE header " + partnerRules.header(student: demoStudent, course: aloneCourse, courseName: "Analysis I", sheetTitle: "Blatt 1")
            .map(\.label).joined(separator: " | "))
        model.showDemo(request: "Show the substitution step in 1(b) in more detail",
                       note: "I expanded the substitution in 1(b) into two steps.",
                       solution: demoSolution, markup: demoMarkup, rules: partnerRules, student: demoStudent,
                       course: CourseDetails(group: "Gruppe 3", partners: [Partner(name: "Grace Hopper")]))
        model.showDemoState(phase: .needsDetails([.partnerMatrikelnr]))
        await panelShot(window, "needs-details-partner")
        print("FILENAME demo \(model.suggestedFilename)")

        // The rules call failed: Solve waits for Retry or Continue Without Rules.
        model.showDemoRulesFailed("ChatGPT returned an error: HTTP 500")
        await panelShot(window, "rules-failed")
    }

    private static func panelShot(_ window: NSWindow, _ name: String) async {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp.appearance = NSAppearance(named: appearance)
            try? await Task.sleep(for: .seconds(1))
            if let png = try? await Snapshotter.capture(window) {
                print("SHOT:panel-\(name)-\(appearance == .aqua ? "light" : "dark"):" + png.base64EncodedString())
            }
        }
        NSApp.appearance = NSAppearance(named: .aqua)
    }

    /// A PDF page as a PNG, 900 px wide.
    private static func pagePNG(_ page: PDFPage?) -> Data? {
        guard let page else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        let image = page.thumbnail(of: CGSize(width: 900, height: 900 * bounds.height / bounds.width), for: .mediaBox)
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
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

/// `--solve-check live [assignmentId] [--dry]`: one real open assignment, solved typed with the real
/// ChatGPT sign-in and data, then shown handwritten when a handwriting library is set up. Prints the
/// phases, the rules, the file name, where each source chip points, PDFSAME and `SHOT:` lines, and
/// quits. Nothing is handed in or uploaded (Moodle is only read); the student's details are never
/// filled in or saved. `--dry` stops before the first ChatGPT call.
@MainActor
extension SolveCheck {
    static func live(ask: AskModel, service: MoodleSubmissions?, overview: PortalOverview, assignmentId: Int64?, dry: Bool,
                     openMaterial: @escaping (PortalOverview.ItemRow) async throws -> URL) async {
        let started = Date()
        // `--synthetic-handwriting`: a made-up handwriting (a font, photographed and read back), so the
        // handwritten path runs for real without the student's own samples.
        if CommandLine.arguments.contains("--synthetic-handwriting"),
           let library = TemplateCheck.syntheticLibrary(named: "solve-check-live-glyphs") {
            Handwriter.library = library
        }
        // `--skip-memory`: Skip for Now as soon as the memory step starts (no digest calls).
        let skipMemory = CommandLine.arguments.contains("--skip-memory")
        func log(_ line: String) {
            print(String(format: "[%7.1fs] ", Date().timeIntervalSince(started)) + line)
            fflush(stdout)
        }
        defer {
            fflush(stdout)
            NSApp.terminate(nil)
        }
        guard let service else { log("LIVE no Moodle token"); return }

        // 1. The assignment: open, a Moodle assignment, not handed in; course 9's family first.
        let algorithms = overview.courses.first { $0.id == 9 }
        let courseList = overview.courses.map { (id: $0.id, name: $0.shortName + " " + $0.fullName, active: $0.active) }
        let preferred = Set(algorithms.map { CourseLinks.related(courseId: 9, courseName: $0.shortName + " " + $0.fullName, courses: courseList) } ?? [])
        let now = Date()
        for item in overview.openDeadlines where assignmentId == nil {
            let reason = item.source != .moodle ? "not on Moodle (\(item.source.rawValue))"
                : MoodleSubmissions.cmid(fromURL: item.url) == nil ? "no assignment link"
                : (item.date ?? .distantPast) <= now ? "deadline passed or unknown" : nil
            if let reason { log("EXCLUDED [\(item.id)] \(item.course) | \(item.title) | \(reason)") }
        }
        let deadlines = overview.openDeadlines
            .filter { assignmentId == nil ? ($0.source == .moodle && ($0.date ?? .distantPast) > now) : $0.id == assignmentId }
            .filter { MoodleSubmissions.cmid(fromURL: $0.url) != nil }
            .sorted { (preferred.contains($0.courseId) ? 0 : 1, $0.date ?? .distantFuture) < (preferred.contains($1.courseId) ? 0 : 1, $1.date ?? .distantFuture) }
        log("LIVE \(deadlines.count) open Moodle assignment(s); preferred courses \(preferred.sorted())")
        var picked: (item: PortalOverview.ItemRow, rules: AssignmentRules, state: SubmissionState)?
        var fallback: (item: PortalOverview.ItemRow, rules: AssignmentRules, state: SubmissionState)?
        for item in deadlines.prefix(8) {
            guard let cmid = MoodleSubmissions.cmid(fromURL: item.url) else { continue }
            do {
                let rules = try await service.rules(cmid: cmid)
                let state = try await service.state(assignId: rules.assignId)
                let best = SheetFinder.best(SheetFinder.candidates(assignment: rules.name, deadline: item, overview: overview))
                log("CANDIDATE [\(item.id)] \(item.course) | \(rules.name) | due \(item.date.map { DueText.date($0) } ?? "-") | status \(state.status.rawValue) canEdit \(state.canEdit) graded \(state.graded) | sheet \(best?.name ?? "-") | attachments \(rules.attachments.count)")
                // A given id may already be handed in (the Solve button needs only canEdit); never handed in again here.
                guard assignmentId != nil || state.status != .submitted, state.canEdit, !state.graded else { continue }
                if best != nil || !rules.attachments.isEmpty {
                    picked = (item, rules, state)
                    break
                }
                if fallback == nil { fallback = (item, rules, state) }
            } catch {
                log("CANDIDATE [\(item.id)] \(item.course) | \(item.title) | Moodle: \(error)")
            }
        }
        guard let (item, rules, state) = picked ?? fallback else { log("LIVE no open assignment to solve"); return }
        log("CHOSEN [\(item.id)] cmid \(rules.cmid) | \(item.course) (\(item.courseFullName)) | \(rules.name) | due \(item.date.map { DueText.date($0) } ?? "-") | status \(state.status.rawValue), \(state.files.count) file(s) on Moodle")
        if !preferred.contains(item.courseId) && assignmentId == nil { log("CHOSEN outside course 9's family") }

        // 2. The model, as the Solve button makes it.
        let storedFormat = UserDefaults.standard.string(forKey: "solveFormat")
        defer { UserDefaults.standard.set(storedFormat, forKey: "solveFormat") }
        let candidates = SheetFinder.candidates(assignment: rules.name, deadline: item, overview: overview)
        let courseIds = SheetFinder.courses(of: item, overview: overview)
        let model = SolveModel(assignment: rules, service: service, ask: ask, database: ask.database, deadline: item,
                               courseIds: courseIds, courseName: item.courseFullName, courseShort: item.course,
                               candidates: candidates, openMaterial: openMaterial)
        defer { model.stop() }
        model.format = .typed
        log("SHEET \(model.sheet.name ?? "(none)"); needsSheet \(model.needsSheet); sheet number \(model.sheetNumber.map(String.init) ?? "-")")
        for candidate in candidates.prefix(3) { log("      \(candidate.score)  \(candidate.name)  [\(candidate.item.course)]") }
        log("COURSES \(courseIds.map { id in overview.courses.first { $0.id == id }?.shortName ?? String(id) })")
        let own = CourseLinks.words(item.course + " " + item.courseFullName)
        for id in courseIds.dropFirst() {
            guard let other = overview.courses.first(where: { $0.id == id }) else { continue }
            log("LINKED \(other.shortName) (\(other.fullName)) shares \(own.intersection(CourseLinks.words(other.shortName + " " + other.fullName)).sorted())")
        }
        let list = courseIds.map(String.init).joined(separator: ",")
        let pdfs = (try? await ask.database.writer.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM uni_item i JOIN uni_file f ON f.item_id = i.id
                WHERE i.kind = 'material' AND i.deleted_at IS NULL AND lower(f.filename) LIKE '%.pdf' AND i.course_id IN (\(list.isEmpty ? "0" : list))
                """) ?? 0
        }) ?? 0
        let document = model.memoryDocument()
        log("MEMORY pdfs \(pdfs), digests \(document?.files.count ?? 0), not read \(document?.unread.count ?? 0) → about \(max(0, pdfs - (document?.files.count ?? 0) - (document?.unread.count ?? 0))) file(s) to digest")
        let student = model.student, course = model.courseDetails
        func filled(_ value: String) -> String { value.trimmingCharacters(in: .whitespaces).isEmpty ? "empty" : "set" }
        log("DETAILS name \(filled(student.name)), matrikelnr \(filled(student.matrikelnr)), email \(filled(student.email)); group \(filled(course.group)), tutorial \(filled(course.tutorial)), partners \(course.partners.count), alone \(course.alone)")
        log("HANDWRITING library set up: \(Handwriter.isSetUp)")
        await ask.refreshAccount()
        log("CHATGPT signed in \(model.signedIn) (plan \(ask.account?.canUsePlan == true), model \(ask.model ?? "none"))")

        var attached: (name: String, data: Data)?
        func panel(showsRules: Bool = false, showsUnread: Bool = false) -> NSWindow {
            let window = NSWindow(contentViewController: NSHostingController(rootView:
                SolvePanel(model: model, ask: ask, acceptsFiles: rules.acceptsFiles, acceptsText: rules.acceptsText,
                           attach: { attached = ($0, $1) }, useAsText: { _ in }, openMemory: { _ in }, close: {},
                           showsRules: showsRules, showsUnread: showsUnread)
                    .frame(width: 520, height: 720)))
            window.makeKeyAndOrderFront(nil)
            return window
        }
        // The panel starts the model when it appears: a dry run stops before showing it.
        if dry {
            // What the rules call reads besides the sheet: its digest (from the memory, when built).
            if case .material(let candidate) = model.sheet,
               let digest = document?.files.first(where: { $0.itemId == candidate.item.id })?.digest {
                print("SHEET DIGEST BEGIN\n\(digest)\nSHEET DIGEST END")
            }
            if case .material(let candidate) = model.sheet, let url = try? await openMaterial(candidate.item),
               let pdf = PDFDocument(url: url) {
                let text = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n")
                print("SHEET TEXT \(pdf.pageCount) page(s), \(text.count) chars BEGIN\n\(text)\nSHEET TEXT END")
            }
            log("DRY done: no ChatGPT call made")
            return
        }
        let window = panel()
        guard model.signedIn, !model.needsSheet else { log("LIVE can't solve: signed in \(model.signedIn), needsSheet \(model.needsSheet)"); return }

        // 3. Solve, typed: start() once; the phases as they come.
        func describe(_ phase: SolveModel.Phase) -> String {
            switch phase {
            case .idle: "idle"
            case .reading(let message): "reading: \(message)"
            case .memory(let progress): "memory \(progress.done)/\(progress.total)\(progress.current.map { " reading \($0)" } ?? "")"
            case .rules: "rules"
            case .needsDetails(let fields): "needsDetails \(fields.map(\.rawValue))"
            case .writing: "writing"
            case .failed(let message): "failed: \(message)"
            }
        }
        var requests = 0
        var bypassed = false
        model.start()
        guard model.preparing != nil else { log("LIVE start() did nothing (phase \(describe(model.phase)))"); return }
        var last = ""
        let deadline = Date().addingTimeInterval(40 * 60)
        while Date() < deadline {
            let now = describe(model.phase)
            if now != last {
                if case .writing = model.phase { requests += 1; log("SOLVE REQUEST #\(requests)") }
                log("PHASE \(now)")
                last = now
            }
            if skipMemory, case .memory = model.phase {
                log("SKIP FOR NOW (memory)")
                model.skipMemory()
            }
            if model.rulesError != nil, model.rules == nil, !model.isBusy, model.preparing == nil {
                log("RULES FAILED: \(model.rulesError ?? "")")
                await panelShot(window, "live-rules-failed")
                break
            }
            if case .needsDetails(let fields) = model.phase, !bypassed {
                log("NEEDS DETAILS \(fields.map(\.rawValue)) — the form is shown; nothing is filled in")
                await panelShot(window, "live-needs-details")
                // Debug only: solve anyway, so the rest can be checked; the header leaves the missing rows out.
                bypassed = true
                model.phase = .idle
                model.reply(to: nil)
                continue
            }
            if case .failed = model.phase { break }
            if model.messages.last?.failed == true { break }
            if model.revision > 0, !model.isBusy, model.preparing == nil { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard model.revision > 0 else {
            log("LIVE no solution: phase \(describe(model.phase)), last message \(model.messages.last?.text ?? "-")")
            await panelShot(window, "live-failed")
            return
        }
        log("SOLVED revision \(model.revision), \(requests) solve request(s)\(bypassed ? " (details form bypassed)" : "")")
        print("NOTE \(model.messages.last?.text ?? "")")
        print("SOLUTION BEGIN\n\(model.solution)\nSOLUTION END")
        fflush(stdout)

        // The rules, the header and the file name (the student's values replaced by placeholders).
        let found = model.rules ?? .none
        log("RULES header \(found.header.map(\.rawValue)) | filename \(found.filename ?? "-") | other \(found.other) | quote \(found.quote ?? "-")")
        let student2 = model.student, course2 = model.courseDetails
        var secrets: [(String, String)] = [(student2.matrikelnr, "<matrikelnr>"), (student2.email, "<email>"), (student2.name, "<name>")]
        let nameParts = student2.name.split(separator: " ").map(String.init)
        if let lastName = nameParts.last { secrets.append((lastName, "<lastname>")) }
        if let firstName = nameParts.first { secrets.append((firstName, "<firstname>")) }
        for partner in course2.partners { secrets += [(partner.matrikelnr, "<partner matrikelnr>"), (partner.name, "<partner name>")] }
        func redact(_ text: String) -> String {
            secrets.filter { $0.0.count >= 2 }.reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1, options: .caseInsensitive) }
        }
        log("HEADER " + model.headerRows.map { "\($0.label): \(redact($0.value))" }.joined(separator: " | "))
        log("FILENAME \(redact(model.suggestedFilename))")
        log("UNREAD \(model.unread.map { "\($0.title) — \($0.reason)" })")

        // Where each source chip points.
        log("EXCERPTS sent: " + model.excerpts.map { "[\($0.number)] \($0.title) p.\($0.page)" }.joined(separator: "; "))
        for source in model.sources {
            switch source {
            case .excerpt(let number):
                guard let excerpt = model.excerpts.first(where: { $0.number == number }) else {
                    log("SOURCE [\(number)] → no such excerpt (chip dropped)")
                    continue
                }
                let material = overview.materials.first { $0.id == excerpt.itemId }
                let pageText = (try? await ask.database.writer.read { db in
                    try String.fetchAll(db, sql: "SELECT text FROM uni_page WHERE item_id = ? AND page = ?", arguments: [excerpt.itemId, excerpt.page]).joined(separator: "\n")
                }) ?? ""
                let probe = String(excerpt.text.prefix(40))
                log("SOURCE [\(number)] → \(material?.filename ?? material?.title ?? "item \(excerpt.itemId) NOT IN MATERIALS") [\(excerpt.course)] page \(excerpt.page); excerpt on that page: \(pageText.contains(probe)); \"\(excerpt.text.prefix(100).replacingOccurrences(of: "\n", with: " "))\"")
            case .memory(let section):
                log("SOURCE memory \"\(section)\" → \(model.memoryHeading(for: section) ?? "NO MATCH")")
            }
        }

        // 4. The panel and the PDFs: typed, then handwritten.
        func output(_ format: SolveModel.Format, seconds: Double) async -> Data? {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                if let output = model.output[format], output.revision == model.revision { return output.data }
                if model.outputError != nil { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            log("PDF \(format.rawValue) not ready: \(model.outputError ?? "timed out")")
            return nil
        }
        func check(_ format: SolveModel.Format, shown: Data) async {
            attached = nil
            if let attachment = try? await model.attachment() { attached = (attachment.filename, attachment.data) }
            let opened = try? await model.pdf()  // what Open PDF writes
            log("PDFSAME \(format.rawValue) attachment \(attached?.data == shown) openPDF \(opened == shown) (\(shown.count) bytes, name matches \(attached?.name == model.suggestedFilename))")
            if let document = PDFDocument(data: shown) {
                log("PDF \(format.rawValue): \(document.pageCount) page(s)")
                for index in 0..<min(document.pageCount, 6) {
                    if let png = pagePNG(document.page(at: index)) { print("SHOT:live-pdf-\(format.rawValue)-p\(index + 1):" + png.base64EncodedString()) }
                }
            }
        }
        if let typed = await output(.typed, seconds: 120) {
            await check(.typed, shown: typed)
        }
        await panelShot(window, "live-typed")
        let rulesWindow = panel(showsRules: true)
        await panelShot(rulesWindow, "live-rules-expanded")
        rulesWindow.orderOut(nil)
        if !model.unread.isEmpty {
            let unreadWindow = panel(showsUnread: true)
            await panelShot(unreadWindow, "live-unread-expanded")
            unreadWindow.orderOut(nil)
        }
        window.makeKeyAndOrderFront(nil)

        guard Handwriter.isSetUp else {
            log("HANDWRITING not set up: no handwriting library at \(Handwriter.library.path)")
            model.format = .handwritten
            await panelShot(window, "live-handwritten-not-set-up")
            return
        }
        model.format = .handwritten
        var lastHandwriting = ""
        let handwritingDeadline = Date().addingTimeInterval(10 * 60)
        while Date() < handwritingDeadline {
            let now: String = switch model.handwriting {
            case .none: "none"
            case .converting: "converting"
            case .rendering: "rendering"
            case .ready(let rendering, _): "ready (\(rendering.pages.count) page(s), dropped \(rendering.dropped))"
            case .failed(let message): "failed: \(message)"
            case .notSetUp: "not set up"
            }
            if now != lastHandwriting { log("HANDWRITING \(now)"); lastHandwriting = now }
            switch model.handwriting {
            case .ready, .failed, .notSetUp: break
            default:
                try? await Task.sleep(for: .milliseconds(500))
                continue
            }
            break
        }
        let firstConversions = model.conversionCalls
        log("CONVERSIONS \(firstConversions) (first handwritten version)")
        let firstHandwritten = await output(.handwritten, seconds: 60)
        if let firstHandwritten {
            await check(.handwritten, shown: firstHandwritten)
        }
        await panelShot(window, "live-handwritten")

        // A header change writes the handwriting again from the markup it has: no new conversion.
        // A made-up value for this PDF only (an override, never saved).
        model.overrideHeader(.name, value: "Ada Lovelace")
        log("HEADER changed: " + model.headerRows.map { "\($0.label): \($0.value)" }.joined(separator: " | "))
        let rewriteDeadline = Date().addingTimeInterval(5 * 60)
        while Date() < rewriteDeadline {
            if case .ready(_, let rendered) = model.handwriting, rendered == model.revision, model.output[.handwritten] == nil || model.output[.handwritten]?.revision == model.revision { break }
            if case .failed = model.handwriting { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        if let rewritten = await output(.handwritten, seconds: 60) {
            log("REWRITTEN differs \(rewritten != firstHandwritten)")
            await check(.handwritten, shown: rewritten)
        }
        log("CONVERSIONS after header change \(model.conversionCalls) (new: \(model.conversionCalls - firstConversions))")
        await panelShot(window, "live-handwritten-header-changed")
        log("LIVE done")
    }
}
#endif
