import Foundation
import GRDB
import Testing
@testable import UniversityKit

/// Everything beyond files and assignment deadlines: activity deadlines, forum threads with
/// replies, grades, messages, course page text and attached files.
@Suite struct MoodleImportTests {
    @Test func activityDeadlinesComeFromTheCalendarWithoutAssignmentsOrOpenings() async throws {
        let harness = try MoodleHarness()
        _ = try await harness.sync().runFast()
        let feedback = try harness.items(.deadline).filter { $0.category == "feedback" }
        #expect(feedback.map(\.title) == ["Registration for the Course"])
        #expect(feedback.first?.externalId == "6001")
        #expect(feedback.first?.url == "https://moodle.uni-saarland.de/mod/feedback/index.php?id=101")
        #expect(!(try harness.items(.deadline)).contains { $0.externalId == "6002" || $0.externalId == "6003" })
    }

    @Test func threadsCarryTheirRepliesAndForum() async throws {
        let harness = try MoodleHarness()
        _ = try await harness.sync().runFast()
        let thread = try #require(try harness.items(.discussion).first)
        #expect(thread.details?["forum"] == "Q&A")
        #expect(thread.details?["replies"] == "1")
        let posts = PortalOverview.ItemRow.posts(thread.bodyHtml ?? "", author: thread.category, date: thread.startsAt)
        #expect(posts.map(\.author) == ["Student Example", "Tutor Example"])
        #expect(posts.map(\.text) == ["Is it all or nothing?", "Partial points per subtask."])
        #expect(posts.last?.date == Date(timeIntervalSince1970: 1_792_500_000))
        // Announcements without replies keep their post as it was.
        let announcement = try #require(try harness.items(.announcement).first { $0.title == "Sheet 1 is out" })
        #expect(announcement.bodyHtml == "<p>See materials.</p>")
        #expect(announcement.details?["replies"] == "0")
    }

    @Test func moreRepliesMakeAReadThreadNewAgain() async throws {
        let harness = try MoodleHarness()
        _ = try await harness.sync().runFast()
        try await harness.database.writer.write { db in try db.execute(sql: "UPDATE uni_item SET read_at = ?", arguments: [fixtureNow]) }

        harness.moodle.override("mod_forum_get_discussion_posts", json: """
            {"posts":[{"id":920,"message":"<p>Is it all or nothing?</p>","timecreated":1792400000,"author":{"fullname":"Student Example"}},
                      {"id":921,"message":"<p>Partial points.</p>","timecreated":1792500000,"author":{"fullname":"Tutor Example"}},
                      {"id":922,"message":"<p>Thanks!</p>","timecreated":1792600000,"author":{"fullname":"Student Example"}}]}
            """)
        _ = try await harness.sync().runFast()
        let thread = try #require(try harness.items(.discussion).first)
        #expect(thread.details?["replies"] == "2")
        #expect(thread.readAt == nil)
        #expect(try harness.items(.announcement).allSatisfy { $0.readAt != nil })
    }

    @Test func gradesKeepGradebookOrderAndOnlyShowGivenGrades() async throws {
        let harness = try MoodleHarness()
        _ = try await harness.sync().runFast()
        let all = try harness.items(.grade)
        let pm = all.filter { $0.courseId == all.first!.courseId }
            .sorted { ($0.position ?? 0) < ($1.position ?? 0) }
        #expect(pm.map(\.title) == ["Blatt 1", "Blatt 2", "Course total"])  // the category row is skipped
        #expect(pm.map(\.category) == ["8,00", nil, nil])
        #expect(pm[0].details?["range"] == "0–10")
        #expect(pm[0].details?["percentage"] == "80,00 %")
        #expect(pm[0].bodyHtml == "<p>Good work</p>")
        #expect(pm[1].details?["percentage"] == nil)
        #expect(pm[2].details?["total"] == "1")
        #expect(pm[0].url == "https://moodle.uni-saarland.de/mod/assign/view.php?id=900")
    }

    @Test func aNewGradeIsNews() async throws {
        let harness = try MoodleHarness()
        _ = try await harness.sync().runFast()
        try await harness.database.writer.write { db in try db.execute(sql: "UPDATE uni_item SET read_at = ?", arguments: [fixtureNow]) }
        harness.moodle.override("gradereport_user_get_grade_items", json: """
            {"usergrades":[{"gradeitems":[
              {"id":1,"itemname":"Blatt 1","itemtype":"mod","itemmodule":"assign","cmid":900,"graderaw":8,"gradeformatted":"8,00","rangeformatted":"0&ndash;10","percentageformatted":"80,00 %","weightformatted":"50,00 %","feedback":"<p>Good work</p>","gradedategraded":1792500000},
              {"id":2,"itemname":"Blatt 2","itemtype":"mod","itemmodule":"assign","cmid":901,"graderaw":9,"gradeformatted":"9,00","rangeformatted":"0&ndash;10","percentageformatted":"90,00 %"},
              {"id":4,"itemtype":"course","graderaw":null,"gradeformatted":"-","rangeformatted":"0&ndash;20"}]}]}
            """)
        _ = try await harness.sync().runFast()
        let sheet2 = try harness.items(.grade).filter { $0.title == "Blatt 2" }
        #expect(sheet2.allSatisfy { $0.category == "9,00" && $0.readAt == nil })
        #expect(try harness.items(.grade).filter { $0.title == "Blatt 1" }.allSatisfy { $0.readAt != nil })
    }

    @Test func conversationsAreStoredWithMessagesOldestFirst() async throws {
        let harness = try MoodleHarness()
        _ = try await harness.sync().runFast()
        let conversations = try await harness.database.writer.read { db in try UniConversation.fetchAll(db) }
        let conversation = try #require(conversations.first)
        #expect(conversations.count == 1)
        #expect(conversation.name == "Tutor Example")
        #expect(conversation.unreadCount == 1)
        #expect(conversation.messages.map(\.text) == ["Hi, am I registered?", "Your registration is confirmed."])
        #expect(conversation.messages.map(\.mine) == [true, false])
        #expect(conversation.messages.map(\.author) == ["Test Student", "Tutor Example"])

        harness.moodle.override("core_message_get_conversations", json: #"{"conversations":[]}"#)
        _ = try await harness.sync().runFast()
        #expect(try await harness.database.writer.read { db in try UniConversation.fetchCount(db) } == 0)
    }

    @Test func coursePageTextIsImportedInPageOrder() async throws {
        let harness = try MoodleHarness()
        _ = try await harness.sync().runFast()
        _ = try await harness.sync().runMaterials()
        let notes = try harness.items(.note).sorted { ($0.position ?? 0) < ($1.position ?? 0) }
        // The course summary, then section 1: its summary and its activities in page order.
        #expect(notes.map(\.externalId) == ["course", "section:1", "module:901", "module:404", "page:405"])
        #expect(notes.first.map { HTMLText.plainText($0.bodyHtml ?? "") } == "Lectures on Mondays, 10:15, in E2 2.")
        #expect(notes.first { $0.externalId == "module:404" }?.title == "")  // a label has no title of its own
        #expect(notes.first { $0.externalId == "page:405" }?.title == "Exam rules")
        let intro = try #require(notes.first { $0.externalId == "module:901" })
        #expect(intro.title == "Blatt 2")
        #expect(HTMLText.plainText(intro.bodyHtml ?? "") == "Solve all tasks & upload one PDF.")
    }

    @Test func assignmentAndForumFilesBecomeMaterials() async throws {
        let harness = try MoodleHarness()
        _ = try await harness.sync().runFast()
        _ = try await harness.sync().runMaterials()
        let materials = try harness.items(.material)
        let byId = Dictionary(uniqueKeysWithValues: materials.map { ($0.externalId, $0) })
        #expect(byId["assign:901/blatt2.pdf"]?.title == "blatt2.pdf")
        #expect(byId["post:320/notes.pdf"]?.category == "Q&A")
        #expect(byId["post:921/rubric.pdf"]?.title == "rubric.pdf")
        let files = try await harness.database.writer.read { db in try UniFile.fetchAll(db) }
        #expect(files.contains { $0.remoteUrl.hasSuffix("/mod_assign/introattachment/0/blatt2.pdf") && $0.sizeBytes == 4096 })
    }

    @Test func migratingToV7KeepsItemsFilesAndIndex() throws {
        let queue = try DatabaseQueue()
        try UniDatabase.migrator.migrate(queue, upTo: "v6_material_pages")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO uni_source (kind) VALUES ('moodle')")
            try db.execute(sql: "INSERT INTO uni_course (source_id, external_id, short_name, full_name) VALUES (1, '101', 'PM', 'Process Mining')")
            try db.execute(sql: """
                INSERT INTO uni_item (course_id, kind, external_id, title, content_hash, first_seen_at, updated_at, location, due_changed_at)
                VALUES (1, 'material', 'f1', 'Slides', 'h', '2026-10-01', '2026-10-01', 'E2 2', '2026-10-02')
                """)
            try db.execute(sql: "INSERT INTO uni_file (item_id, filename, remote_url, local_path) VALUES (1, 'slides.pdf', 'https://x', 'cache/a.pdf')")
            try db.execute(sql: "INSERT INTO uni_index (item_id, pages, chunks, indexed_at) VALUES (1, 3, 4, '2026-10-03')")
        }
        try UniDatabase.migrator.migrate(queue)
        try queue.read { db in
            let item = try #require(try UniItem.fetchOne(db, key: 1))
            #expect(item.title == "Slides" && item.location == "E2 2" && item.dueChangedAt != nil && item.position == nil)
            #expect(try UniFile.fetchOne(db, key: 1)?.localPath == "cache/a.pdf")
            #expect(try Int.fetchOne(db, sql: "SELECT pages FROM uni_index WHERE item_id = 1") == 3)
            #expect(try db.foreignKeyViolations().next() == nil)
        }
        try queue.write { db in
            var grade = UniItem(courseId: 1, kind: .grade, externalId: "g1", title: "Blatt 1", contentHash: "h",
                                details: ["range": "0–10"])
            try grade.insert(db)
            try db.execute(sql: "DELETE FROM uni_item WHERE id = 1")
            #expect(try UniFile.fetchCount(db) == 0)  // cascades still work after the rebuild
        }
    }
}
