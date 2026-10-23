import Foundation
import GRDB
import Testing
@testable import UniversityKit

/// Runs `cms.public` against the real cms.sic.saarland (public pages only, one request per second).
/// Off by default: `UNI_LIVE_CMS=prog1_26,i2cl_2627 swift test --filter LiveCMSTests`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["UNI_LIVE_CMS"] != nil))
struct LiveCMSTests {
    @Test func publicSyncAgainstTheRealSite() async throws {
        let slugs = ProcessInfo.processInfo.environment["UNI_LIVE_CMS"]!.split(separator: ",").map(String.init)
        let database = try UniDatabase.inMemory()
        let sync = CMSSync(database: database, client: CMSClient(transport: URLSessionTransport(session: URLSession(configuration: .ephemeral))))

        let listing = try await sync.courseListing()
        for slug in slugs {
            let course = try #require(listing.first { $0.slug == slug }, "\(slug) is not on /system/courses")
            try database.setCMSCourse(course, selected: true)
        }

        let first = try await sync.runPublic()
        let second = try await sync.runPublic()

        let lines = try await database.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT c.external_id AS slug, i.kind, count(*) AS n, sum(i.is_exam) AS exams,
                       group_concat(DISTINCT i.category) AS categories
                FROM uni_item i JOIN uni_course c ON c.id = i.course_id GROUP BY 1, 2 ORDER BY 1, 2
                """).map { row in
                "LIVE \(row["slug"] as String) \(row["kind"] as String): \(row["n"] as Int) items, \(row["exams"] as Int) exams, categories: \(row["categories"] as String? ?? "-")"
            }
        }
        print("LIVE first run: \(first.counts.dictionary)")
        print("LIVE second run: \(second.counts.dictionary)")
        lines.forEach { print($0) }
        let exams = try await database.writer.read { db in
            try UniItem.filter(sql: "is_exam = 1").order(sql: "starts_at").fetchAll(db)
        }
        for exam in exams { print("LIVE exam: \(exam.title) \(exam.startsAt!.formatted(.iso8601))") }
        let news = try await database.writer.read { db in
            try UniItem.filter(sql: "kind = 'announcement'").order(sql: "starts_at DESC").limit(5).fetchAll(db)
        }
        for item in news { print("LIVE news: \(item.title) \(item.startsAt?.formatted(.iso8601) ?? "no date")") }

        #expect(second.counts.new == 0)
        #expect(second.counts.updated == 0)
    }
}
