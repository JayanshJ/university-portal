import CoreText
import Foundation
import GRDB
import Testing
@testable import UniversityKit

/// A real PDF with one text block per page.
func makePDF(_ pages: [String]) -> Data {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    let consumer = CGDataConsumer(data: data as CFMutableData)!
    let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
    for text in pages {
        context.beginPDFPage(nil)
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 11, nil),
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0),
                                             CGPath(rect: box.insetBy(dx: 40, dy: 40), transform: nil), nil)
        CTFrameDraw(frame, context)
        context.endPDFPage()
    }
    context.closePDF()
    return data as Data
}

@Suite struct PageTextTests {
    @Test func pagesAreReadAndChunkedWithPageNumbers() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let long = Array(repeating: "Tail recursion keeps the stack constant because the call is the last step.", count: 30)
            .joined(separator: " ")
        try makePDF(["Introduction to Programming 1", "", long]).write(to: url)

        let pages = try #require(PageText.pages(of: url))
        #expect(pages.count == 3)
        let chunks = PageText.chunks(pages: pages)
        #expect(chunks.first?.page == 1)
        #expect(!chunks.contains { $0.page == 2 })  // empty page skipped
        let third = chunks.filter { $0.page == 3 }
        #expect(third.count >= 2)  // a long page is split…
        #expect(third.allSatisfy { $0.text.count <= 1_000 })
        #expect(chunks.map(\.ordinal) == Array(0..<chunks.count))  // …and ordinals run across the document
    }

    @Test func nonPDFIsNotReadable() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("%PDF-1.7 fake".utf8).write(to: url)
        #expect(PageText.pages(of: url) == nil)
    }
}

/// A database with two indexed materials, written directly.
func indexedDatabase() throws -> (UniDatabase, process: Int64, demis: Int64, sheet: Int64) {
    let database = try UniDatabase.inMemory()
    return try database.writer.write { db in
        var source = UniSource(kind: .moodle)
        try source.insert(db)
        var pm = UniCourse(sourceId: source.id!, externalId: "1", shortName: "Process Mining", fullName: "Process Mining")
        try pm.insert(db)
        var demisCourse = UniCourse(sourceId: source.id!, externalId: "2", shortName: "DeMIS", fullName: "DeMIS")
        try demisCourse.insert(db)

        func material(_ course: Int64, _ title: String, _ pages: [(Int, String)]) throws -> Int64 {
            var item = UniItem(courseId: course, kind: .material, externalId: title, title: title, contentHash: "x")
            try item.insert(db)
            for (ordinal, page) in pages.enumerated() {
                try db.execute(sql: "INSERT INTO uni_page (item_id, page, ordinal, text) VALUES (?, ?, ?, ?)",
                               arguments: [item.id, page.0, ordinal, page.1])
            }
            try db.execute(sql: "INSERT INTO uni_index (item_id, pages, chunks, indexed_at) VALUES (?, ?, ?, ?)",
                           arguments: [item.id, pages.count, pages.count, Date.now])
            return item.id!
        }
        let process = try material(pm.id!, "PM Lecture 03 Alpha Miner.pdf", [
            (1, "Process discovery overview."),
            (2, "The alpha miner algorithm discovers a Petri net from an event log."),
            (3, "Limitations of the alpha miner: it cannot handle short loops and noise."),
            (4, "Inductive miner guarantees sound process models."),
        ])
        let demis = try material(demisCourse.id!, "DeMIS Lecture 01 Introduction.pdf", [
            (1, "Informationssysteme in der modernen Welt."),
            (2, "Geschäftsprozesse und ihre Modellierung mit BPMN."),
        ])
        let sheet = try material(demisCourse.id!, "6. Übungsblatt.pdf", [
            (1, "Aufgabe 1: Modellieren Sie den Bestellprozess."),
            (2, "Aufgabe 2: Erläutern Sie die Rolle von Gateways."),
        ])
        return (database, process, demis, sheet)
    }
}

@Suite struct RetrieverTests {
    @Test func bestPagesAreCitedWithNeighbours() throws {
        let (database, process, _, _) = try indexedDatabase()

        let excerpts = try Retriever(database: database).excerpts(for: "What are the limitations of the alpha miner?")

        #expect(excerpts.first?.itemId == process)
        #expect(excerpts.contains { $0.page == 3 && $0.text.contains("short loops") })
        #expect(excerpts.contains { $0.page == 4 })  // neighbour of the best hit
        #expect(excerpts.map(\.number) == Array(1...excerpts.count))
        #expect(excerpts.first?.course == "Process Mining")
    }

    @Test func expansionTermsFindGermanSlides() throws {
        let (database, _, demis, _) = try indexedDatabase()
        let retriever = Retriever(database: database)

        // Without German terms, "processes" only reaches the English Process Mining slides.
        #expect(try retriever.excerpts(for: "How are business processes modelled?").first?.itemId != demis)
        let excerpts = try retriever.excerpts(for: "How are business processes modelled?",
                                              extraTerms: ["Geschäftsprozesse", "Modellierung", "BPMN"])
        #expect(excerpts.first?.itemId == demis)
        #expect(excerpts.contains { $0.itemId == demis && $0.page == 2 })
    }

    @Test func namedMaterialIsIncludedEvenWithoutMatchingWords() throws {
        let (database, _, _, sheet) = try indexedDatabase()

        let excerpts = try Retriever(database: database).excerpts(for: "Give me hints for übungsblatt 6")

        #expect(excerpts.contains { $0.itemId == sheet && $0.page == 1 })
        #expect(excerpts.contains { $0.itemId == sheet && $0.page == 2 })
    }

    @Test func courseFilterRestrictsResults() throws {
        let (database, _, _, _) = try indexedDatabase()
        let demisCourse = try database.writer.read { db in try Int64.fetchOne(db, sql: "SELECT id FROM uni_course WHERE external_id = '2'") }

        let excerpts = try Retriever(database: database).excerpts(for: "alpha miner Petri net", courseId: demisCourse)

        #expect(excerpts.allSatisfy { $0.course == "DeMIS" })
    }

    @Test func budgetIsRespected() throws {
        let database = try UniDatabase.inMemory()
        try database.writer.write { db in
            var source = UniSource(kind: .moodle)
            try source.insert(db)
            var course = UniCourse(sourceId: source.id!, externalId: "1", shortName: "C", fullName: "C")
            try course.insert(db)
            var item = UniItem(courseId: course.id!, kind: .material, externalId: "x", title: "Big.pdf", contentHash: "x")
            try item.insert(db)
            for ordinal in 0..<40 {
                try db.execute(sql: "INSERT INTO uni_page (item_id, page, ordinal, text) VALUES (?, ?, ?, ?)",
                               arguments: [item.id, ordinal + 1, ordinal, "recursion " + String(repeating: "word ", count: 150)])
            }
            try db.execute(sql: "INSERT INTO uni_index (item_id, pages, chunks, indexed_at) VALUES (?, 40, 40, ?)",
                           arguments: [item.id, Date.now])
        }
        let excerpts = try Retriever(database: database).excerpts(for: "recursion")
        #expect(excerpts.map(\.text.count).reduce(0, +) <= Retriever.budget)
        #expect(excerpts.count >= 5)
    }

    @Test(arguments: [
        ("übungsblatt 6", "6. Übungsblatt.pdf", true),
        ("uebungsblatt 6", "6_Uebungsblatt.pdf", true),
        ("bungblatt 6", "6_Uebungsblatt.pdf", true),
        ("Kapitel 6", "6_Uebungsblatt.pdf", false),
        ("make 6 flashcards", "6_Uebungsblatt.pdf", false),
        ("summarise lecture 1", "DeMIS Lecture 01 Introduction.pdf", true),
        ("summarise lecture 2", "DeMIS Lecture 01 Introduction.pdf", false),
        ("what is in DeMIS Lecture 01 Introduction", "DeMIS Lecture 01 Introduction.pdf", true),
    ])
    func materialReferences(question: String, title: String, matches: Bool) {
        #expect(MaterialReference.detect(in: question, titles: [(7, title)]) == (matches ? [7] : []))
    }
}

@Suite struct IndexerTests {
    @Test func indexesPDFsOnceAndAgainWhenChanged() async throws {
        let harness = try MoodleHarness()
        harness.moodle.serveFile("01-intro.pdf", data: makePDF(["Welcome to Process Mining", "The alpha miner discovers Petri nets."]))
        harness.moodle.serveFile("sheet1.pdf", data: makePDF(["Exercise sheet 1: model an order process."]))
        harness.moodle.serveFile("script.pdf", data: Data("not a pdf".utf8))
        _ = try await harness.sync().runFast()
        _ = try await harness.sync().runMaterials()
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let indexer = MaterialIndexer(database: harness.database, files: MaterialFiles(
            database: harness.database, cache: FileCache(directory: directory), secrets: harness.secrets, transport: harness.moodle))

        let first = await indexer.run()

        #expect(first.total == 3)  // the three PDFs; data.zip and the link are not PDFs
        #expect(first.failed == 1)  // script.pdf is not a real PDF
        let status = try indexer.status()
        #expect(status.indexed == 2)
        #expect(try harness.items(.material).allSatisfy { $0.readAt != nil })  // first import; indexing didn't change it
        let excerpts = try Retriever(database: harness.database).excerpts(for: "alpha miner")
        #expect(excerpts.first?.title == "01-intro.pdf")
        #expect(excerpts.contains { $0.title == "01-intro.pdf" && $0.page == 2 && $0.text.contains("alpha miner") })

        // Nothing new: only the failed file is retried.
        let second = await indexer.run()
        #expect(second.total == 1)
    }
}

@Suite struct AskServiceTests {
    @Test func citationsAreParsed() {
        #expect(AskService.citations(in: "Short loops fail [2]. Noise too [1][3], see [2, 4].") == [2, 1, 3, 4])
        #expect(AskService.citations(in: "No sources.").isEmpty)
    }

    @Test func promptNumbersExcerptsWithCourseFileAndPage() {
        let prompt = AskService.prompt(question: "Why?", excerpts: [
            Excerpt(number: 1, itemId: 1, courseId: 1, title: "PM 03.pdf", course: "Process Mining", page: 14, text: "Because."),
        ])
        #expect(prompt.contains("[1] Process Mining — PM 03.pdf, page 14\nBecause."))
        #expect(prompt.hasSuffix("Question: Why?"))
    }
}
