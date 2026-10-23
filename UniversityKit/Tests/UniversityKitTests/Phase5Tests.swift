import Foundation
import GRDB
import Testing
@testable import UniversityKit

@Suite struct ReadStateTests {
    @Test func firstImportIsReadButLaterAdditionsAreNew() async throws {
        let harness = try MoodleHarness()
        _ = try await harness.sync().runFast()
        _ = try await harness.sync().runMaterials()
        #expect(try harness.items(.announcement).allSatisfy { $0.readAt != nil })
        #expect(try harness.items(.material).allSatisfy { $0.readAt != nil })

        // A new discussion appears in a course that already had announcements.
        let more = String(decoding: fixture("mod_forum_get_forum_discussions.13"), as: UTF8.self)
            .replacingOccurrences(of: #"{"discussions":["#, with: #"{"discussions":[{"id":902,"discussion":311,"subject":"Sheet 2 is out","message":"<p>Now.</p>","created":1792756000,"userfullname":"Tutor Example"},"#)
        harness.moodle.override("mod_forum_get_forum_discussions.13", json: more)
        _ = try await harness.sync().runFast()

        let unread = try harness.items(.announcement).filter { $0.readAt == nil }.map(\.title)
        #expect(unread == ["Sheet 2 is out"])
        // Deadlines have no read state.
        #expect(try harness.items(.deadline).allSatisfy { $0.readAt == nil })
    }

    @Test func markingReadClearsItFromNewSinceVisit() async throws {
        let harness = try MoodleHarness()
        _ = try await harness.sync().runFast()
        try harness.database.markTodayVisited(at: fixtureNow.addingTimeInterval(-3600))
        let item = try #require(try harness.items(.announcement).first)
        try harness.database.setRead(itemId: item.id!, read: false)
        try await harness.database.writer.write { db in
            try db.execute(sql: "UPDATE uni_item SET first_seen_at = ? WHERE id = ?", arguments: [Date.now, item.id])
        }
        var overview = try await harness.database.writer.read(PortalOverview.fetch)
        #expect(overview.newSinceVisit.announcements.map(\.id) == [item.id!])

        try harness.database.setRead(itemId: item.id!)

        overview = try await harness.database.writer.read(PortalOverview.fetch)
        #expect(overview.newSinceVisit.announcements.isEmpty)
    }

    @Test func doneAndUndo() async throws {
        let harness = try MoodleHarness()
        _ = try await harness.sync().runFast()
        let deadline = try #require(try harness.items(.deadline).first)

        try harness.database.setDone(itemId: deadline.id!, done: true)
        var overview = try await harness.database.writer.read(PortalOverview.fetch)
        #expect(!overview.openDeadlines.contains { $0.id == deadline.id })
        #expect(overview.doneDeadlines.first?.doneSource == .user)

        try harness.database.setDone(itemId: deadline.id!, done: false)
        overview = try await harness.database.writer.read(PortalOverview.fetch)
        #expect(overview.openDeadlines.contains { $0.id == deadline.id })
    }

    @Test func movedDeadlineIsMarkedAsChanged() async throws {
        let harness = try MoodleHarness()
        _ = try await harness.sync().runFast()
        let moved = String(decoding: fixture("core_calendar_get_action_events_by_timesort"), as: UTF8.self)
            .replacingOccurrences(of: "1793404740", with: "1793491140")
        harness.moodle.override("core_calendar_get_action_events_by_timesort", json: moved)
        _ = try await harness.sync().runFast()

        let changed = try harness.items(.deadline).filter { $0.dueChangedAt != nil }.map(\.title)
        #expect(changed == ["Blatt 2"])
    }
}

@Suite struct EventHubTests {
    @Test func listenersReceivePublishedEvents() async {
        let hub = UniEventHub()
        let stream = hub.events()
        hub.publish([.itemCreated(itemId: 1), .itemUpdated(itemId: 2, dueDateChanged: true)])

        var received: [UniEvent] = []
        for await event in stream {
            received.append(event)
            if received.count == 2 { break }
        }
        #expect(received == [.itemCreated(itemId: 1), .itemUpdated(itemId: 2, dueDateChanged: true)])
    }

    @Test func schedulerPublishesWhatARunCreated() async throws {
        let harness = try MoodleHarness()
        let hub = UniEventHub()
        let stream = hub.events()
        let scheduler = SyncScheduler(database: harness.database, secrets: harness.secrets,
                                      transport: harness.moodle, events: hub)

        await scheduler.run(.moodleFast)

        var created = 0
        for await event in stream {
            if case .itemCreated = event { created += 1 }
            if created == 6 { break }
        }
        #expect(created == 6)
    }
}

@Suite struct ScheduleAndTextTests {
    @Test func scheduleMixesEventsAndDeadlinesAndRespectsHiddenCategories() async throws {
        let database = try UniDatabase.inMemory()
        let cms = FakeCMS()
        let sync = CMSSync(database: database, client: CMSClient(transport: cms, minimumInterval: .zero), now: { fixtureNow })
        let listing = try #require(try await sync.courseListing().first { $0.slug == "prog1_26" })
        try database.setCMSCourse(listing, selected: true)
        _ = try await sync.runPublic()

        let week = ISO8601DateFormatter().date(from: "2026-12-07T00:00:00+01:00")!
        var items = try database.schedule(from: week, to: week.addingTimeInterval(7 * 86_400))
        #expect(items.contains { $0.title == "Midterm" && $0.isExam })
        #expect(items.contains { $0.section == "Tutorial" })

        let courseId = try #require(items.first?.courseId)
        try database.setCategory("Tutorial", hidden: true, courseId: courseId)
        items = try database.schedule(from: week, to: week.addingTimeInterval(7 * 86_400))
        #expect(!items.contains { $0.section == "Tutorial" })
        #expect(items.map(\.date).allSatisfy { $0! >= week })
    }

    @Test func announcementHTMLBecomesReadableText() {
        let html = #"<p>The tutorials are now assigned.</p><p>Tutorials start next Tuesday.&nbsp;<br />Office hours: <a href="x">here</a>.</p><ul><li>One</li><li>Two</li></ul>"#
        #expect(HTMLText.plainText(html) == "The tutorials are now assigned.\n\nTutorials start next Tuesday.\nOffice hours: here.\n\n• One\n\n• Two")
    }
}
