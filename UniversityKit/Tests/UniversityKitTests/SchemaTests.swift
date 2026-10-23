import Foundation
import GRDB
import Testing
@testable import UniversityKit

@Suite struct SchemaTests {
    @Test func migrationsCreateEveryTable() throws {
        let database = try UniDatabase.inMemory()
        let missing = try database.writer.read { db in
            try UniDatabase.tableNames.filter { try !db.tableExists($0) }
        }
        #expect(missing.isEmpty)
    }

    @Test func rerunningMigrationsIsANoOp() throws {
        let queue = try DatabaseQueue()
        let first = try UniDatabase(queue)
        try first.writer.write { db in
            var source = UniSource(kind: .moodle)
            try source.insert(db)
        }
        let applied = try queue.read { db in try UniDatabase.migrator.appliedMigrations(db) }

        let second = try UniDatabase(queue)

        let (reapplied, sources) = try second.writer.read { db in
            (try UniDatabase.migrator.appliedMigrations(db), try UniSource.fetchCount(db))
        }
        #expect(reapplied == applied)
        #expect(sources == 1)
    }

    @Test func duplicateItemKeyIsRejected() throws {
        let database = try UniDatabase.inMemory()
        try database.writer.write { db in
            var source = UniSource(kind: .moodle)
            try source.insert(db)
            var course = UniCourse(sourceId: source.id!, externalId: "42", shortName: "PM", fullName: "Process Mining")
            try course.insert(db)
            var item = UniItem(courseId: course.id!, kind: .deadline, externalId: "1001", title: "Sheet 1", contentHash: "a")
            try item.insert(db)

            var duplicate = UniItem(courseId: course.id!, kind: .deadline, externalId: "1001", title: "Sheet 1 (again)", contentHash: "b")
            #expect {
                try duplicate.insert(db)
            } throws: { error in
                (error as? DatabaseError)?.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE
            }

            // Same external id under another kind is a different item.
            var announcement = UniItem(courseId: course.id!, kind: .announcement, externalId: "1001", title: "News", contentHash: "c")
            try announcement.insert(db)
        }
    }

    @Test func recordsRoundTripThroughSnakeCaseColumns() throws {
        let database = try UniDatabase.inMemory()
        let course = try database.writer.write { db in
            var source = UniSource(kind: .cms)
            try source.insert(db)
            var course = UniCourse(sourceId: source.id!, externalId: "prog1_26", shortName: "Prog 1",
                                   fullName: "Programmierung 1", hiddenCategories: ["Tutorial"])
            try course.insert(db)
            return course
        }

        let fetched = try database.writer.read { db in try UniCourse.fetchOne(db, key: course.id) }
        #expect(fetched?.externalId == "prog1_26")
        #expect(fetched?.hiddenCategories == ["Tutorial"])
    }

    @Test func stateValuesRoundTrip() throws {
        let database = try UniDatabase.inMemory()
        let passport = MoodlePassport(value: "abcdef0123456789", expiresAt: Date(timeIntervalSince1970: 1_800_000_000))

        try database.setState(.pdfDarkPages, to: true)
        try database.setState(.moodlePassport, to: passport)

        #expect(try database.state(.pdfDarkPages, as: Bool.self) == true)
        #expect(try database.state(.moodlePassport, as: MoodlePassport.self) == passport)

        try database.removeState(.moodlePassport)
        #expect(try database.state(.moodlePassport, as: MoodlePassport.self) == nil)
    }
}
