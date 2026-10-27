import Foundation
import Testing
@testable import UniversityKit

@Suite struct TextScheduleTests {
    let sources = [
        TextSchedule.Source(item: UniItem(courseId: 1, kind: .note, externalId: "module:1", title: "",
                                          bodyHtml: "<p>Capstone Session: Wednesday, 14:15 – 15:45h, (B4.1, 0.04)</p>",
                                          url: "https://moodle.uni-saarland.de/course/view.php?id=1", contentHash: "a"),
                            label: "Course page text"),
        TextSchedule.Source(item: UniItem(courseId: 1, kind: .announcement, externalId: "9", title: "Capstone Teams Notification",
                                          url: "https://moodle.uni-saarland.de/mod/forum/discuss.php?d=9", contentHash: "b"),
                            label: "Announcement"),
    ]
    /// Tuesday 27 Oct 2026, 16:00 in Saarbrücken.
    let today = Date(timeIntervalSince1970: 1_793_113_200)

    @Test func theReplyIsReadEvenWithProseAround() {
        let found = TextSchedule.parse("""
            Here you go:
            [{"title":"Capstone Session","type":"session","date":"2026-10-28","start":"14:15","end":"15:45","weekly":true,
              "until":"2026-11-18","location":"B4.1, 0.04","mandatory":false,"source":0,"quote":"Capstone Session: Wednesday, 14:15"},
             {"title":"Pitch presentation","type":"presentation","date":"2026-11-04","start":"14:15","end":"15:45","weekly":false,
              "until":null,"location":"B4.1, 0.04","mandatory":true,"source":1,"quote":"next week's pitch session"}]
            """)
        #expect(found.map(\.title) == ["Capstone Session", "Pitch presentation"])
        #expect(TextSchedule.parse("Nothing found.").isEmpty)
        #expect(TextSchedule.parse("[]").isEmpty)
    }

    @Test func weeklySessionsRepeatUntilTheirEndInLocalTime() throws {
        let found = [TextSchedule.Found(title: "Capstone Session", type: "session", date: "2026-10-28", start: "14:15", end: "15:45",
                                        weekly: true, until: "2026-11-18", location: "B4.1, 0.04", mandatory: false, source: 0, quote: "Wednesday, 14:15")]
        let events = TextSchedule.events(found, sources: sources, courseId: 1, today: today)
        #expect(events.count == 4)  // 28 Oct, 4, 11 and 18 Nov
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let first = try #require(events.first?.startsAt)
        #expect(calendar.component(.hour, from: first) == 14 && calendar.component(.minute, from: first) == 15)
        #expect(calendar.component(.weekday, from: first) == 4)  // Wednesday
        #expect(events.first?.endsAt == first.addingTimeInterval(90 * 60))
        #expect(events.allSatisfy { $0.kind == .event && $0.category == "Session" && $0.location == "B4.1, 0.04" })
        #expect(Set(events.map(\.externalId)).count == 4)
        #expect(events.first?.url == "https://moodle.uni-saarland.de/course/view.php?id=1")
        #expect(events.first?.details?["weekly"] == "1")
    }

    @Test func aPresentationIsMandatoryAndLinksToTheAnnouncement() {
        let found = [TextSchedule.Found(title: "Pitch presentation", type: "presentation", date: "2026-11-04", start: "14:15", end: nil,
                                        weekly: false, until: nil, location: nil, mandatory: true, source: 1, quote: "next week's pitch session")]
        let event = TextSchedule.events(found, sources: sources, courseId: 1, today: today).first
        #expect(event?.category == "Presentation")
        #expect(event?.details?["mandatory"] == "1")
        #expect(event?.details?["quote"] == "next week's pitch session")
        #expect(event?.details?["from"] == "Announcement")
        #expect(event?.url == "https://moodle.uni-saarland.de/mod/forum/discuss.php?d=9")
        #expect(event?.allDay == false && event?.endsAt == nil)
    }

    @Test func badEntriesAreSkippedAndExamsAreExams() {
        let found = [
            TextSchedule.Found(title: "Mid-term exam", type: "exam", date: "2026-12-03", start: "18:30", end: nil, weekly: false,
                               until: nil, location: nil, mandatory: true, source: 0, quote: nil),
            TextSchedule.Found(title: "Bad source", type: "event", date: "2026-12-03", start: nil, end: nil, weekly: false,
                               until: nil, location: nil, mandatory: nil, source: 7, quote: nil),
            TextSchedule.Found(title: "Bad date", type: "event", date: "December", start: nil, end: nil, weekly: false,
                               until: nil, location: nil, mandatory: nil, source: 0, quote: nil),
        ]
        let events = TextSchedule.events(found, sources: sources, courseId: 1, today: today)
        #expect(events.map(\.title) == ["Mid-term exam"])
        #expect(events.first?.isExam == true)
    }
}
