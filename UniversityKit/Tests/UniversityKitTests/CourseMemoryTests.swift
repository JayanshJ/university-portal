import Foundation
import GRDB
import Testing
@testable import UniversityKit

@Suite struct CourseMemoryTests {
    @Test func migrationCreatesMemoryTables() throws {
        let database = try UniDatabase(DatabaseQueue())
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let (file, memory) = try database.writer.write { db -> (MemoryFile, CourseMemoryRecord) in
            var source = UniSource(kind: .moodle)
            try source.insert(db)
            var course = UniCourse(sourceId: source.id!, externalId: "1", shortName: "WI1", fullName: "Wirtschaftsinformatik 1")
            try course.insert(db)
            var item = UniItem(courseId: course.id!, kind: .note, externalId: "f1", title: "Skript", contentHash: "a")
            try item.insert(db)
            let file = MemoryFile(itemId: item.id!, courseId: course.id!, sha256: "abc", promptVersion: 1, model: "m",
                                  digest: "Digest", edited: true, updatedAt: stamp, error: nil)
            try file.insert(db)
            let memory = CourseMemoryRecord(courseId: course.id!, overview: "Overview", overviewEdited: true,
                                            notes: "Notes", overviewSignature: "sig", updatedAt: stamp)
            try memory.insert(db)
            return (file, memory)
        }
        let (fetchedFile, fetchedMemory) = try database.writer.read { db in
            (try MemoryFile.fetchOne(db, key: file.itemId), try CourseMemoryRecord.fetchOne(db, key: memory.courseId))
        }
        #expect(fetchedFile == file)
        #expect(fetchedMemory == memory)
    }

    @Test func relatedFindsTheCMSTwin() {
        let related = CourseLinks.related(courseId: 1, courseName: "Wirtschaftsinformatik 1", courses: [
            (1, "Wirtschaftsinformatik 1", true), (2, "Wirtschaftsinformatik 1 (CMS)", true),
            (3, "Statistik", true), (4, "Wirtschaftsinformatik alt", false),
        ])
        #expect(related == [1, 2])
    }

}

/// Records what the fake model is asked; throws for inputs containing "FAIL".
final class FakeModel: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(instructions: String, input: String)] = []
    var calls: [(instructions: String, input: String)] { lock.withLock { _calls } }
    var complete: CourseMemory.Complete {
        { [self] instructions, input in
            lock.withLock { _calls.append((instructions, input)) }
            if input.contains("FAIL") { throw URLError(.badServerResponse) }
            return "digest of " + input.prefix(20)
        }
    }
}

private func seedMemory(_ database: UniDatabase, pdfs: [(course: Int, title: String, pages: [String])]) throws -> [Int64] {
    try database.writer.write { db in
        var source = UniSource(kind: .moodle)
        try source.insert(db)
        for course in Set(pdfs.map(\.course)).sorted() {
            var c = UniCourse(sourceId: source.id!, externalId: String(course), shortName: "C\(course)", fullName: "Course \(course)")
            try c.insert(db)
        }
        var ids: [Int64] = []
        for (n, pdf) in pdfs.enumerated() {
            let courseId = try Int64.fetchOne(db, sql: "SELECT id FROM uni_course WHERE external_id = ?", arguments: [String(pdf.course)])!
            var item = UniItem(courseId: courseId, kind: .material, externalId: "m\(n)", title: pdf.title, contentHash: "x")
            try item.insert(db)
            try UniFile(itemId: item.id!, filename: pdf.title + ".pdf", sizeBytes: 1000, remoteUrl: "https://x/\(n)", sha256: "sha\(n)").insert(db)
            for (ordinal, text) in pdf.pages.enumerated() {
                try db.execute(sql: "INSERT INTO uni_page (item_id, page, ordinal, text) VALUES (?, ?, ?, ?)",
                               arguments: [item.id, ordinal + 1, ordinal, text])
            }
            try db.execute(sql: "INSERT INTO uni_index (item_id, sha256, pages, chunks, indexed_at) VALUES (?, ?, ?, ?, ?)",
                           arguments: [item.id, "sha\(n)", pdf.pages.count, pdf.pages.count, Date.now])
            ids.append(item.id!)
        }
        return ids
    }
}

@Suite struct CourseMemoryBuilderTests {
    private func setup(_ pdfs: [(course: Int, title: String, pages: [String])]) throws -> (UniDatabase, [Int64], FakeModel, CourseMemory) {
        let database = try UniDatabase.inMemory()
        let ids = try seedMemory(database, pdfs: pdfs)
        let model = FakeModel()
        return (database, ids, model, CourseMemory(database: database, complete: model.complete, model: "m"))
    }
    private let two: [(course: Int, title: String, pages: [String])] = [(1, "Lecture 1", ["a", "b"]), (1, "Lecture 2", ["c"])]

    @Test func digestsEachIndexedFileOnce() async throws {
        let (database, _, model, memory) = try setup(two)
        let progress = await memory.run(courseIds: [1], memoryCourseId: 1, onProgress: { _ in })
        #expect(progress.done == 2 && progress.failed.isEmpty)
        #expect(try await database.writer.read { try MemoryFile.fetchCount($0) } == 2)
        #expect(model.calls.count == 3)  // 2 digests + 1 overview
        _ = await memory.run(courseIds: [1], memoryCourseId: 1, onProgress: { _ in })
        #expect(model.calls.count == 3)
    }

    @Test func aChangedFileIsReadAgain() async throws {
        let (database, ids, model, memory) = try setup(two)
        _ = await memory.run(courseIds: [1], memoryCourseId: 1, onProgress: { _ in })
        try await database.writer.write { try $0.execute(sql: "UPDATE uni_index SET sha256 = 'new' WHERE item_id = ?", arguments: [ids[0]]) }
        let before = model.calls.count
        _ = await memory.run(courseIds: [1], memoryCourseId: 1, onProgress: { _ in })
        #expect(model.calls.count - before == 2)
    }

    @Test func longFilesAreReadInPartsThenCondensed() async throws {
        let pages = (0..<13).map { _ in String(repeating: "x", count: 10_000) }
        let (_, _, model, memory) = try setup([(1, "Long", pages)])
        _ = await memory.run(courseIds: [1], memoryCourseId: 1, onProgress: { _ in })
        let calls = model.calls
        #expect(calls.count == 5)  // 3 parts + condense + overview
        for call in calls.prefix(3) { #expect(call.input.count <= CourseMemory.partSize) }
    }

    @Test func editedDigestsAndNotesSurvive() async throws {
        let (database, ids, _, memory) = try setup(two)
        _ = await memory.run(courseIds: [1], memoryCourseId: 1, onProgress: { _ in })
        try memory.setDigest("mine", itemId: ids[0])
        try memory.setNotes("keep", courseId: 1)
        try await database.writer.write { try $0.execute(sql: "UPDATE uni_index SET sha256 = 'new' WHERE item_id = ?", arguments: [ids[0]]) }
        #expect(try memory.pending(courseIds: [1]).isEmpty)
        _ = await memory.run(courseIds: [1], memoryCourseId: 1, onProgress: { _ in })
        let (digest, notes) = try await database.writer.read {
            (try MemoryFile.fetchOne($0, key: ids[0])!.digest, try CourseMemoryRecord.fetchOne($0, key: 1)!.notes)
        }
        #expect(digest == "mine" && notes == "keep")
        try memory.reread(itemId: ids[0])
        #expect(try memory.pending(courseIds: [1]).map(\.itemId) == [ids[0]])
    }

    @Test func deletedFilesLeaveTheMemory() async throws {
        let (database, ids, _, memory) = try setup(two)
        _ = await memory.run(courseIds: [1], memoryCourseId: 1, onProgress: { _ in })
        try memory.setDigest("mine", itemId: ids[1])
        try await database.writer.write { try $0.execute(sql: "UPDATE uni_item SET deleted_at = ? WHERE id = ?", arguments: [Date.now, ids[1]]) }
        _ = await memory.run(courseIds: [1], memoryCourseId: 1, onProgress: { _ in })
        #expect(try await database.writer.read { try MemoryFile.fetchOne($0, key: ids[1]) } == nil)
    }

    @Test func aFailureKeepsWhatWasDone() async throws {
        let (database, ids, model, memory) = try setup([(1, "One", ["a"]), (1, "Two", ["FAIL"]), (1, "Three", ["c"])])
        let progress = await memory.run(courseIds: [1], memoryCourseId: 1, onProgress: { _ in })
        #expect(progress.failed == ["Two"])
        let rows = try await database.writer.read { try MemoryFile.fetchAll($0, sql: "SELECT * FROM uni_memory_file ORDER BY item_id") }
        #expect(rows.count == 3)
        #expect(rows[0].digest != "" && rows[2].digest != "" && rows[1].error != nil)
        #expect(try memory.unread(courseIds: [1]).map(\.title) == ["Two"])
        try await database.writer.write { try $0.execute(sql: "UPDATE uni_page SET text = 'ok' WHERE item_id = ?", arguments: [ids[1]]) }
        let before = model.calls.count
        _ = await memory.run(courseIds: [1], memoryCourseId: 1, onProgress: { _ in })
        #expect(model.calls.count - before == 2)  // file 2 + overview
        #expect(try memory.unread(courseIds: [1]).isEmpty)
    }

    @Test func rebuildKeepsNotes() async throws {
        let (_, _, _, memory) = try setup(two)
        _ = await memory.run(courseIds: [1], memoryCourseId: 1, onProgress: { _ in })
        try memory.setNotes("keep", courseId: 1)
        try memory.rebuild(memoryCourseId: 1, courseIds: [1])
        #expect(try memory.pending(courseIds: [1]).count == 2)
    }

    @Test func relatedCoursesAreIncluded() async throws {
        let (database, _, _, memory) = try setup([(1, "A", ["a"]), (2, "B", ["b"])])
        _ = await memory.run(courseIds: [1, 2], memoryCourseId: 1, onProgress: { _ in })
        let courses = try await database.writer.read { try Int64.fetchAll($0, sql: "SELECT course_id FROM uni_memory_file ORDER BY course_id") }
        #expect(courses.count == 2 && courses[0] != courses[1])
    }

    @Test func unreadListsUnindexedAndOversizedFiles() async throws {
        let (database, ids, _, memory) = try setup(two)
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE uni_index SET error = 'scanned' WHERE item_id = ?", arguments: [ids[0]])
            try db.execute(sql: "DELETE FROM uni_index WHERE item_id = ?", arguments: [ids[1]])
            try db.execute(sql: "UPDATE uni_file SET size_bytes = ? WHERE item_id = ?", arguments: [MaterialIndexer.maxBytes + 1, ids[1]])
        }
        let unread = try memory.unread(courseIds: [1])
        #expect(unread.map(\.reason) == ["scanned", "too large"])
    }
}
