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
