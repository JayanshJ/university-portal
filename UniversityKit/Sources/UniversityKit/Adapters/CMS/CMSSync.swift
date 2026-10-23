import Foundation
import GRDB

/// The public CMS job (`cms.public`): news and calendar of every selected course. No login needed.
public struct CMSSync: Sendable {
    let database: UniDatabase
    let client: CMSClient
    let now: @Sendable () -> Date

    private static let examPattern = try! NSRegularExpression(pattern: "exam|klausur|prüfung", options: .caseInsensitive)

    public init(database: UniDatabase, client: CMSClient, now: @escaping @Sendable () -> Date = { .now }) {
        self.database = database
        self.client = client
        self.now = now
    }

    /// Every course on `/system/courses`, for the course picker.
    public func courseListing() async throws -> [CMSCourseListing] {
        try CMSPages.courses(try await client.get("/system/courses"))
    }

    public func runPublic() async throws -> SyncOutcome {
        let now = now()
        let sourceId = try database.source(.cms).id!
        let courses = try await database.writer.read { db in
            try UniCourse.filter(Column("source_id") == sourceId && Column("active") == true).fetchAll(db)
        }

        var news: [ItemInput] = []
        var events: [ItemInput] = []
        for course in courses {
            guard let courseId = course.id else { continue }
            let slug = course.externalId
            news += try await fetchNews(slug: slug, courseId: courseId)
            events += try await fetchEvents(slug: slug, courseId: courseId)
        }

        let scope = Set(courses.compactMap(\.id))
        let (foundNews, foundEvents) = (news, events)
        return try await database.writer.write { db in
            try Upserter.apply(db, kind: .announcement, courseIds: scope, items: foundNews, now: now)
                + Upserter.apply(db, kind: .event, courseIds: scope, items: foundEvents, now: now)
        }
    }

    private func fetchNews(slug: String, courseId: Int64) async throws -> [ItemInput] {
        try CMSPages.news(try await client.get("/\(slug)/")).map { entry in
            ItemInput(courseId: courseId, kind: .announcement, externalId: String(entry.id),
                      title: entry.title, bodyHtml: entry.bodyHtml, startsAt: entry.postedAt,
                      url: client.url("/\(slug)/news/view/\(entry.id)").absoluteString,
                      category: entry.author)
        }
    }

    /// The full feed has every event; the per-category feeds say which category each belongs to.
    /// Events are matched by content because CMS issues new UIDs on every download.
    private func fetchEvents(slug: String, courseId: Int64) async throws -> [ItemInput] {
        let categories = try CMSPages.calendarCategories(try await client.get("/\(slug)/termine"), slug: slug)
        var categoryByKey: [String: String] = [:]
        for category in categories {
            let feed = try await client.get("/\(slug)/termine/events/download/\(category.id)")
            for event in ICalendar.events(in: feed) { categoryByKey[event.contentKey] = category.name }
        }

        let all = ICalendar.events(in: try await client.get("/\(slug)/termine/events/download"))
        var occurrences: [String: Int] = [:]
        let calendarURL = client.url("/\(slug)/termine").absoluteString
        return all.map { event in
            // Truly identical events (same title, time and place) get a running number.
            let key = event.contentKey
            occurrences[key, default: 0] += 1
            let externalId = occurrences[key]! == 1 ? key : "\(key)#\(occurrences[key]!)"
            let category = categoryByKey[key] ?? "Other"
            return ItemInput(
                courseId: courseId, kind: .event, externalId: externalId, title: event.summary,
                bodyHtml: event.description, startsAt: event.start, endsAt: event.end,
                location: event.location, allDay: event.allDay, url: calendarURL, category: category,
                isExam: Self.examPattern.firstMatch(in: category, range: NSRange(category.startIndex..., in: category)) != nil)
        }
    }
}

extension UniDatabase {
    /// Ticking a course in the picker. Unticking keeps its data but stops syncing and showing it.
    public func setCMSCourse(_ listing: CMSCourseListing, selected: Bool) throws {
        try writer.write { db in
            let sourceId = try Self.source(db, .cms).id!
            let ids = try Upserter.upsertCourses(db, sourceId: sourceId, [CourseInput(
                externalId: listing.slug, shortName: listing.name, fullName: listing.name,
                url: CMSClient.siteURL.appending(path: listing.slug).absoluteString, active: false)])
            guard let id = ids[listing.slug], var course = try UniCourse.fetchOne(db, key: id) else { return }
            course.activeOverride = selected
            course.active = selected
            try course.update(db)
        }
    }
}
