import Foundation
import GRDB
import Testing
@testable import UniversityKit

func cmsFixture(_ name: String) -> String {
    let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/cms")!
    return try! String(contentsOf: url, encoding: .utf8)
}

/// Serves the recorded public CMS pages by path. Overrides replace a page's body.
final class FakeCMS: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var overrides: [String: String] = [:]
    private var log: [String] = []

    var paths: [String] { lock.withLock { log } }

    func override(_ path: String, with body: String) { lock.withLock { overrides[path] = body } }

    static func fixtureName(for path: String) -> String? {
        switch path {
        case "/system/courses": "system_courses.html"
        case "/prog1_26/": "prog1_26.main.html"
        case "/prog1_26/termine": "prog1_26.termine.html"
        case "/prog1_26/termine/events/download": "prog1_26.events.ics"
        default:
            path.hasPrefix("/prog1_26/termine/events/download/")
                ? "prog1_26.events.\(path.split(separator: "/").last!).ics" : nil
        }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let path = url.path + (url.absoluteString.hasSuffix("/") && url.path != "/" ? "/" : "")
        lock.withLock { log.append(path) }
        let body = lock.withLock { overrides[path] } ?? Self.fixtureName(for: path).map(cmsFixture)
        let status = body == nil ? 404 : 200
        return (Data((body ?? "Not Found").utf8),
                HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

/// Gives every VEVENT a fresh UID, as CMS does on each download.
func withNewUIDs(_ ics: String) -> String {
    ics.split(separator: "\n", omittingEmptySubsequences: false).map { line in
        line.hasPrefix("UID:") ? "UID:\(UUID().uuidString)" : String(line)
    }.joined(separator: "\n")
}

@Suite struct ICalendarTests {
    @Test func readsEveryEventOfTheRecordedFeed() {
        let events = ICalendar.events(in: cmsFixture("prog1_26.events.ics"))
        #expect(events.count == 117)

        let midterm = events.first { $0.summary == "Midterm" }
        #expect(midterm?.start == ISO8601DateFormatter().date(from: "2026-12-11T12:59:00Z"))
        #expect(midterm?.end == ISO8601DateFormatter().date(from: "2026-12-11T16:00:00Z"))
        #expect(midterm?.location == "See personal status page")
        #expect(midterm?.allDay == false)
    }

    @Test func allDayDatesAreBerlinDays() {
        let prep = ICalendar.events(in: cmsFixture("prog1_26.events.ics")).first { $0.summary == "PrepCourse" }
        #expect(prep?.allDay == true)
        #expect(prep?.start == ISO8601DateFormatter().date(from: "2026-09-07T00:00:00+02:00"))
    }

    @Test func foldedLinesAndEscapesAreDecoded() {
        let ics = "BEGIN:VEVENT\r\nDTSTART:20261022T081500Z\r\nSUMMARY:Lecture\r\nDESCRIPTION:Chapter 1.6: recursion\\, div\r\n ergence\\nnext line\\; done\r\nEND:VEVENT\r\n"
        let event = ICalendar.events(in: ics).first
        #expect(event?.description == "Chapter 1.6: recursion, divergence\nnext line; done")
    }

    @Test func localTimesUseTheirTimeZone() {
        let ics = "BEGIN:VEVENT\nDTSTART;TZID=Europe/Berlin:20261022T101500\nSUMMARY:x\nEND:VEVENT\n"
        #expect(ICalendar.events(in: ics).first?.start == ISO8601DateFormatter().date(from: "2026-10-22T08:15:00Z"))
    }

    @Test func contentKeyMatchesAcrossDownloadsDespiteNewUIDs() {
        let full = ICalendar.events(in: cmsFixture("prog1_26.events.ics"))
        let exams = ICalendar.events(in: cmsFixture("prog1_26.events.2.ics"))
        #expect(exams.count == 4)
        #expect(Set(exams.map(\.contentKey)).isSubset(of: Set(full.map(\.contentKey))))
    }
}

@Suite struct CMSPageTests {
    @Test func courseListHasTermsAndSlugs() throws {
        let courses = try CMSPages.courses(cmsFixture("system_courses.html"))
        #expect(courses.count > 200)
        let prog1 = try #require(courses.first { $0.slug == "prog1_26" })
        #expect(prog1.name == "Programming 1")
        #expect(prog1.lecturer == "Sebastian Hack")
        #expect(prog1.term == AcademicTerm(.winter, 2026))
        #expect(courses.contains { $0.slug == "i2cl_2627" })
        #expect(courses.contains { $0.slug == "introalgdat2627" })
        #expect(Set(courses.compactMap(\.term)).count == 4)  // Winter 26/27 back to Summer 25
    }

    @Test func changedCourseListMarkupIsAnError() {
        #expect(throws: CMSPageError.self) { try CMSPages.courses("<html><body><p>Maintenance</p></body></html>") }
    }

    @Test func newsEntryHasDateAuthorAndFullBody() throws {
        let news = try CMSPages.news(cmsFixture("prog1_26.main.html"))
        #expect(news.count == 1)
        let entry = try #require(news.first)
        #expect(entry.id == 1)
        #expect(entry.title == "Tutorial Assignment")
        #expect(entry.author == "Marcel Ullrich")
        #expect(entry.postedAt == ISO8601DateFormatter().date(from: "2026-10-20T12:36:50+02:00"))
        #expect(entry.bodyHtml.contains("will be released on Friday"))  // the full text, not the teaser
        #expect(!entry.bodyHtml.contains("Read more"))
    }

    @Test func germanBylineGivesTheAuthor() throws {
        let html = cmsFixture("prog1_26.main.html").replacingOccurrences(
            of: "Written on <span", with: "Geschrieben am <span"
        ).replacingOccurrences(
            of: "by Marcel Ullrich", with: "(letzte Änderung am 22.10.26) von Margareta Wiegmann Planas")
        #expect(try CMSPages.news(html).first?.author == "Margareta Wiegmann Planas")
    }

    @Test func calendarCategoriesAreRead() throws {
        let categories = try CMSPages.calendarCategories(cmsFixture("prog1_26.termine.html"), slug: "prog1_26")
        #expect(categories.map(\.name).sorted() == ["Events", "Exam", "Lectures", "Other", "Tutorial"])
        #expect(categories.first { $0.name == "Exam" }?.id == 2)
    }
}

@Suite struct CMSSyncTests {
    func harness() throws -> (UniDatabase, FakeCMS, CMSSync) {
        let database = try UniDatabase.inMemory()
        let cms = FakeCMS()
        let sync = CMSSync(database: database, client: CMSClient(transport: cms, minimumInterval: .zero),
                           now: { fixtureNow })
        return (database, cms, sync)
    }

    func selectProg1(_ database: UniDatabase, _ sync: CMSSync) async throws {
        let listing = try #require(try await sync.courseListing().first { $0.slug == "prog1_26" })
        try database.setCMSCourse(listing, selected: true)
    }

    func items(_ database: UniDatabase, _ kind: ItemKind) throws -> [UniItem] {
        try database.writer.read { db in try UniItem.filter(sql: "kind = ?", arguments: [kind.rawValue]).fetchAll(db) }
    }

    @Test func publicSyncStoresExamsAndNews() async throws {
        let (database, _, sync) = try harness()
        try await selectProg1(database, sync)

        let outcome = try await sync.runPublic()

        let events = try items(database, .event)
        #expect(events.count == 117)
        let exams = events.filter(\.isExam).sorted { $0.startsAt! < $1.startsAt! }
        #expect(exams.map(\.title) == ["Midterm", "Midterm Retake", "Endterm", "Endterm Retake"])
        #expect(exams.allSatisfy { $0.category == "Exam" })
        let berlin = { (date: Date) in
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
            return calendar.dateComponents([.month, .day], from: date)
        }
        #expect(berlin(exams[0].startsAt!) == DateComponents(month: 12, day: 11))
        #expect(berlin(exams[2].startsAt!) == DateComponents(month: 2, day: 25))
        #expect(Set(events.compactMap(\.category)) == ["Lectures", "Exam", "Tutorial", "Events", "Other"])

        let news = try items(database, .announcement)
        #expect(news.map(\.title) == ["Tutorial Assignment"])
        #expect(news.first?.url == "https://cms.sic.saarland/prog1_26/news/view/1")
        #expect(outcome.counts.new == 118)
    }

    @Test func secondRunWithFreshUIDsReportsNothingNew() async throws {
        let (database, cms, sync) = try harness()
        try await selectProg1(database, sync)
        _ = try await sync.runPublic()
        cms.override("/prog1_26/termine/events/download", with: withNewUIDs(cmsFixture("prog1_26.events.ics")))
        for n in 1...5 {
            cms.override("/prog1_26/termine/events/download/\(n)", with: withNewUIDs(cmsFixture("prog1_26.events.\(n).ics")))
        }

        let second = try await sync.runPublic()

        #expect(second.counts.new == 0)
        #expect(second.counts.updated == 0)
        #expect(second.counts.unchanged == 118)
    }

    @Test func unselectedCoursesAreNotFetched() async throws {
        let (database, cms, sync) = try harness()
        try await selectProg1(database, sync)
        let listing = try #require(try await sync.courseListing().first { $0.slug == "prog1_26" })
        try database.setCMSCourse(listing, selected: false)

        let outcome = try await sync.runPublic()

        #expect(outcome.counts.new == 0)
        #expect(!cms.paths.contains("/prog1_26/"))
    }

    @Test func schedulerRunsCMSOnlyOnceACourseIsChosen() async throws {
        let (database, cms, sync) = try harness()
        let scheduler = SyncScheduler(database: database, secrets: InMemorySecrets(), transport: cms)

        await scheduler.run(.cmsPublic)
        #expect(try await database.writer.read { db in try UniSyncRun.fetchCount(db) } == 0)

        try await selectProg1(database, sync)
        await scheduler.run(.cmsPublic)
        let run = try await database.writer.read { db in try UniSyncRun.fetchOne(db) }
        #expect(run?.job == "cms.public")
        #expect(run?.ok == true)
        #expect(try database.source(.cms).status == .ok)
    }
}
