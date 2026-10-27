import CryptoKit
import Foundation
import GRDB

/// Dates that Moodle courses only state in words: weekly sessions in the course description
/// ("Capstone Session: Wednesday, 14:15 – 15:45h, B4.1 0.04"), exams under "Important dates",
/// and announcements like "prepare for next week's pitch session". ChatGPT reads each course's
/// page text and recent announcements; the result becomes calendar events linked to their source.
/// A course is read again only when its text changed.
public struct TextSchedule: Sendable {
    let database: UniDatabase
    let client: ResponsesClient
    let now: @Sendable () -> Date

    private static let log = Log(category: "text-schedule")
    static let timeZone = TimeZone(identifier: "Europe/Berlin")!

    public init(database: UniDatabase, client: ResponsesClient, now: @escaping @Sendable () -> Date = { .now }) {
        self.database = database
        self.client = client
        self.now = now
    }

    /// One piece of text the model may cite by its number.
    struct Source {
        var item: UniItem
        var label: String
    }

    /// What the model reports.
    struct Found: Decodable, Equatable {
        var title: String
        var type: String
        var date: String
        var start: String?
        var end: String?
        var weekly: Bool?
        var until: String?
        var location: String?
        var mandatory: Bool?
        var source: Int
        var quote: String?
    }

    /// Reads every active Moodle course whose text changed since the last run. Returns how many courses were read.
    @discardableResult
    public func run(model: String) async throws -> Int {
        let today = now()
        let (courses, sourcesByCourse) = try await database.writer.read { db -> ([UniCourse], [Int64: [UniItem]]) in
            guard let moodle = try UniSource.filter(Column("kind") == SourceKind.moodle.rawValue).fetchOne(db)?.id else { return ([], [:]) }
            let courses = try UniCourse.filter(Column("source_id") == moodle && Column("active") == true).fetchAll(db)
            var sources: [Int64: [UniItem]] = [:]
            for course in courses {
                guard let id = course.id else { continue }
                sources[id] = try UniItem
                    .filter(Column("course_id") == id && Column("deleted_at") == nil)
                    .filter(Column("kind") == ItemKind.note.rawValue
                            || (Column("kind") == ItemKind.announcement.rawValue && Column("starts_at") > today.addingTimeInterval(-60 * 86_400))
                            || (Column("kind") == ItemKind.discussion.rawValue && Column("starts_at") > today.addingTimeInterval(-30 * 86_400)))
                    .order(Column("kind"), Column("position"), Column("starts_at"))
                    .fetchAll(db)
            }
            return (courses, sources)
        }
        var seen = (try? database.state(.textScheduleInputs, as: [String: String].self)) ?? [:]
        var read = 0
        for course in courses {
            guard let courseId = course.id else { continue }
            let items = sourcesByCourse[courseId] ?? []
            // Relative dates ("next week") depend on the day, so the week is part of the signature.
            let week = Calendar(identifier: .iso8601).component(.weekOfYear, from: today)
            let signature = Self.hash(([String(week), model, Self.version] + items.map { "\($0.id ?? 0):\($0.contentHash)" }).joined(separator: "|"))
            guard seen[String(courseId)] != signature else { continue }

            let sources = items.map { Source(item: $0, label: Self.label($0)) }
            let found = sources.isEmpty ? [] : try await extract(course: course, sources: sources, today: today, model: model)
            let events = Self.events(found, sources: sources, courseId: courseId, today: today)
            try await database.writer.write { db in
                _ = try Upserter.apply(db, kind: .event, courseIds: [courseId], items: events, now: today)
                // A course whose events are all gone: clear them (the zero-results guard keeps them otherwise).
                if events.isEmpty {
                    try db.execute(sql: "UPDATE uni_item SET deleted_at = ? WHERE course_id = ? AND kind = 'event' AND external_id LIKE 'text:%' AND deleted_at IS NULL",
                                   arguments: [today, courseId])
                }
            }
            Self.log.info("Read \(sources.count) texts of course \(courseId): \(found.count) dates, \(events.count) events")
            seen[String(courseId)] = signature
            try database.setState(.textScheduleInputs, to: seen)
            read += 1
        }
        return read
    }

    func extract(course: UniCourse, sources: [Source], today: Date, model: String) async throws -> [Found] {
        var formatter = Date.FormatStyle(date: .complete, time: .omitted)
        formatter.timeZone = Self.timeZone
        formatter.locale = Locale(identifier: "en_GB")
        let texts = sources.enumerated().map { index, source in
            let text = HTMLText.plainText(source.item.bodyHtml ?? "")
            return "[\(index)] \(source.label)\n\(String(text.prefix(4000)))"
        }
        let prompt = """
            Course: \(course.fullName)
            Today: \(today.formatted(formatter))

            \(texts.joined(separator: "\n\n"))
            """
        let reply = try await client.complete(model: model, instructions: Self.instructions,
                                              input: [ChatMessage(role: .user, content: prompt)])
        return Self.parse(reply)
    }

    static func parse(_ reply: String) -> [Found] {
        guard let start = reply.firstIndex(of: "["), let end = reply.lastIndex(of: "]"), start < end,
              let found = try? JSONDecoder().decode([Found].self, from: Data(reply[start...end].utf8)) else { return [] }
        return found
    }

    /// Calendar events from the model's findings: weekly ones repeat from their next occurrence until
    /// their end (at most 20 weeks ahead).
    static func events(_ found: [Found], sources: [Source], courseId: Int64, today: Date) -> [ItemInput] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parseDay = { (text: String?) -> Date? in
            guard let text else { return nil }
            let parts = text.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        }
        let at = { (day: Date, time: String?) -> Date? in
            guard let time else { return nil }
            let parts = time.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2 else { return nil }
            return calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: day)
        }
        var items: [ItemInput] = []
        for entry in found {
            guard let first = parseDay(entry.date), sources.indices.contains(entry.source) else { continue }
            let source = sources[entry.source]
            var days = [first]
            if entry.weekly == true {
                let horizon = min(parseDay(entry.until) ?? .distantFuture, today.addingTimeInterval(140 * 86_400))
                var day = first
                days = []
                while day <= horizon {
                    days.append(day)
                    day = calendar.date(byAdding: .day, value: 7, to: day)!
                }
            }
            let kind = entry.type.lowercased()
            var details = ["source": "text", "from": source.label]
            details["quote"] = entry.quote.flatMap { $0.isEmpty ? nil : String($0.prefix(300)) }
            details["mandatory"] = entry.mandatory == true ? "1" : nil
            details["weekly"] = entry.weekly == true ? "1" : nil
            for day in days {
                let start = at(day, entry.start)
                items.append(ItemInput(
                    courseId: courseId, kind: .event,
                    externalId: "text:" + hash("\(entry.title.lowercased())|\(entry.start ?? "")|\(Int(day.timeIntervalSince1970))").prefix(16),
                    title: entry.title,
                    startsAt: start ?? day, endsAt: at(day, entry.end), location: entry.location,
                    allDay: start == nil, url: source.item.url,
                    category: kind == "exam" ? "Exam" : kind == "presentation" ? "Presentation" : kind == "session" ? "Session" : "Event",
                    isExam: kind == "exam", details: details))
            }
        }
        return items
    }

    static func label(_ item: UniItem) -> String {
        switch item.kind {
        case .announcement, .discussion:
            let posted = item.startsAt.map { day -> String in
                var style = Date.FormatStyle(date: .complete, time: .shortened)
                style.timeZone = timeZone
                style.locale = Locale(identifier: "en_GB")
                return day.formatted(style)
            } ?? "unknown date"
            return "\(item.kind == .announcement ? "Announcement" : "Forum post") \"\(item.title)\", posted \(posted)"
        default:
            return item.title.isEmpty ? "Course page text" : "Course page: \(item.title)"
        }
    }

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Part of each course's signature, so changed instructions read every course again.
    static let version = "2"

    static let instructions = """
        You find the dates a university student must know in their course's texts: recurring sessions \
        (lectures, tutorials, interactive or capstone sessions), exams, presentations or pitch sessions, \
        and other dated events (registration windows, excursions). Texts are numbered; announcements say when \
        they were posted. Resolve relative dates ("next week's pitch session", "tomorrow", "in two weeks") \
        against the posting date of the text that says them, and a weekday-only session ("Wednesday, 14:15") \
        to a weekly event. Times are local (Europe/Berlin).

        Reply with ONLY a JSON array, no prose. Each element:
        {"title": short name, e.g. "Capstone Session" or "Pitch presentation",
         "type": "session" | "exam" | "presentation" | "event",
         "date": "YYYY-MM-DD" (the specific date; for weekly sessions the next occurrence on or after today),
         "start": "HH:MM" or null, "end": "HH:MM" or null,
         "weekly": true for recurring weekly sessions, else false,
         "until": "YYYY-MM-DD" or null (last week of a weekly session, if stated),
         "location": room or "online", or null,
         "mandatory": true if attendance or participation is required,
         "source": the number of the text it comes from,
         "quote": the words from that text that state it (max 200 characters)}

        Only include what a text actually states or clearly implies; never guess times or rooms. \
        Every announcement or post that mentions an upcoming presentation, pitch, exam, session or meeting \
        whose date can be worked out MUST yield its own element, even when it takes place during a regular \
        session: give it that session's date, time and room from the course page, and mark it mandatory if \
        presenting or attending is required. Example: posted Monday 26 Oct, "prepare for next week's pitch \
        session", and the capstone session is on Wednesdays 14:15-15:45 → a "Pitch session" element on \
        Wednesday 4 Nov, 14:15-15:45. \
        When a course lists several alternative groups for the same tutorial, return one element per group \
        and put the group in the title. Don't repeat the same session twice. Don't include assignment due \
        dates (they are already known). If nothing is found, reply [].
        """
}
