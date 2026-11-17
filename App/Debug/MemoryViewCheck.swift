#if DEBUG
import AppKit
import Foundation
import GRDB
import SwiftUI
import UniversityKit

/// Debug aid: `--solve-check views` photographs the course memory view and Settings' "Your Details"
/// and ChatGPT sections over a made-up in-memory database (never the real one), prints
/// "SHOT:<name>:<base64 PNG>" lines and quits. No ChatGPT calls.
@MainActor
enum MemoryViewCheck {
    static func run(ask: AskModel) async {
        defer {
            fflush(stdout)
            NSApp.terminate(nil)
        }
        ask.showDemo(courseId: nil)
        guard let (database, courseId, late) = try? seed() else {
            print("VIEWS seeding failed")
            return
        }
        let summary = try? CourseMemory.viewer(database).summary(courseIds: [courseId])
        print("VIEWS summary \(summary.map(CourseMemoryView.summaryText) ?? "none")")

        // From the top, as the course page opens it.
        await shot("memory-top", CourseMemoryView(database: database, courseName: "Analysis I", courseIds: [courseId],
                                                  memoryCourseId: nil, heading: nil), size: NSSize(width: 560, height: 680))
        // From a source chip naming a later file (edited, changed since): scrolled there, its summary open.
        await shot("memory-heading", CourseMemoryView(database: database, courseName: "Analysis I", courseIds: [courseId],
                                                      memoryCourseId: courseId, heading: late), size: NSSize(width: 560, height: 680))
        // An empty course: no memory yet, details still editable.
        let empty = (try? emptyCourse(database)) ?? courseId
        await shot("memory-empty", CourseMemoryView(database: database, courseName: "Statistik", courseIds: [empty],
                                                    memoryCourseId: nil, heading: nil), size: NSSize(width: 560, height: 680))

        let settings = Form {
            ChatGPTSection(ask: ask)
            YourDetailsSection(database: database)
        }
        .formStyle(.grouped)
        await shot("settings", settings, size: NSSize(width: 540, height: 420))
    }

    /// One course with notes, an overview, 14 summaries (sheet 3 edited and changed since, lecture 05 edited)
    /// and two files not read; the student's name comes from "Moodle", the rest is empty.
    private static func seed() throws -> (UniDatabase, Int64, String) {
        let database = try UniDatabase.inMemory()
        try database.setState(.moodleFullName, to: "Ada Lovelace")
        let titles = ["Vorlesung 01 – Grundlagen", "Vorlesung 02 – Folgen", "Vorlesung 03 – Reihen", "Vorlesung 04 – Stetigkeit",
                      "Vorlesung 05 – Substitution und partielle Integration", "Vorlesung 06 – Taylor", "Übungsblatt 1", "Übungsblatt 2",
                      "Übungsblatt 3", "Übungsblatt 4", "Vorlesung 07 – Uneigentliche Integrale", "Vorlesung 08 – Potenzreihen",
                      "Übungsblatt 5", "Formelsammlung", "Blatt 2 Lösungen (Scan)", "Skript komplett"]
        let courseId = try database.writer.write { db -> Int64 in
            var source = UniSource(kind: .moodle)
            try source.insert(db)
            var course = UniCourse(sourceId: source.id!, externalId: "ana", shortName: "ANA", fullName: "Analysis I")
            try course.insert(db)
            let courseId = course.id!
            let hour: TimeInterval = 3_600
            for (n, title) in titles.enumerated() {
                var item = UniItem(courseId: courseId, kind: .material, externalId: "m\(n)", title: title, contentHash: "x", position: n)
                try item.insert(db)
                try UniFile(itemId: item.id!, filename: title + ".pdf", sizeBytes: 300_000, remoteUrl: "https://x/\(n)", sha256: "s\(n)").insert(db)
                if title.contains("Scan") {
                    try db.execute(sql: "INSERT INTO uni_index (item_id, sha256, pages, chunks, indexed_at, error) VALUES (?, ?, 0, 0, ?, ?)",
                                   arguments: [item.id, "s\(n)", Date.now, "No text in the PDF (a scan)."])
                    continue
                }
                if title == "Skript komplett" { continue }  // not indexed yet
                // The edited summary of sheet 3 was made from an older version of the file.
                let indexSha = title == "Übungsblatt 3" ? "new" : "s\(n)"
                try db.execute(sql: "INSERT INTO uni_index (item_id, sha256, pages, chunks, indexed_at) VALUES (?, ?, 10, 10, ?)",
                               arguments: [item.id, indexSha, Date.now])
                let edited = title.hasPrefix("Vorlesung 05") || title == "Übungsblatt 3"
                let digest = edited
                    ? "## \(title)\n\nMy version: substitution always written as $u = g(x)$, $du = g'(x)\\,dx$; limits changed, never back-substituted.\n- Partielle Integration: **LIATE** order for choosing $u$.\n- Typical sheet task: $\\int_0^1 2x e^{x^2} dx = e - 1$."
                    : "## \(title)\n\nCovers the definitions and main theorems of this part, with the lecture's notation.\n- Key definitions with page numbers [p. 3], [p. 7].\n- Worked examples the sheets reuse.\n1. Theorem first, then proof sketch.\n2. Exercises at the end."
                try MemoryFile(itemId: item.id!, courseId: courseId, sha256: "s\(n)", promptVersion: CourseMemory.promptVersion, model: "demo",
                               digest: digest, edited: edited, updatedAt: Date.now.addingTimeInterval(-2 * hour)).insert(db)
            }
            try CourseMemoryRecord(courseId: courseId,
                                   overview: "## Analysis I\n\nNotation: sequences $(a_n)$, limits with $\\varepsilon$–$N$. Sheets are due Mondays; each has 4 tasks.\n- Lectures 01–04: sequences, series, continuity.\n- Lectures 05–08: integration and power series.\n- Sheets follow the lectures one week later.",
                                   notes: "Tutor wants every step justified. Use the lecture's notation for limits.",
                                   updatedAt: Date.now.addingTimeInterval(-2 * hour)).insert(db)
            return courseId
        }
        return (database, courseId, "Übungsblatt 3")
    }

    private static func emptyCourse(_ database: UniDatabase) throws -> Int64 {
        try database.writer.write { db in
            let sourceId = try Int64.fetchOne(db, sql: "SELECT id FROM uni_source LIMIT 1")!
            var course = UniCourse(sourceId: sourceId, externalId: "stat", shortName: "STAT", fullName: "Statistik")
            try course.insert(db)
            return course.id!
        }
    }

    private static func shot(_ name: String, _ view: some View, size: NSSize) async {
        let window = NSWindow(contentViewController: NSHostingController(rootView: view.frame(width: size.width, height: size.height)))
        window.setContentSize(size)
        window.makeKeyAndOrderFront(nil)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp.appearance = NSAppearance(named: appearance)
            try? await Task.sleep(for: .seconds(1.5))
            if let png = try? await Snapshotter.capture(window) {
                print("SHOT:\(name)-\(appearance == .aqua ? "light" : "dark"):" + png.base64EncodedString())
            }
        }
        NSApp.appearance = NSAppearance(named: .aqua)
        window.orderOut(nil)
    }
}
#endif
