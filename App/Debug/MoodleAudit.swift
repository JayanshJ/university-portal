import AppKit
import Foundation
import UniversityKit

/// Debug aid: launched with `--audit`, the app asks Moodle (read-only) for everything it shows
/// about each active course, writes a report of what exists next to what the app imports, and
/// quits. The report goes to the sandbox's temporary folder:
/// ~/Library/Containers/app.jayansh.UniversityPortal/Data/tmp/audit/moodle.json
@MainActor
enum MoodleAudit {
    static func run(overview: PortalOverview, token: String, transport: any HTTPTransport) async {
        let client = MoodleClient(token: token, transport: transport)
        var report: [String: Any] = [:]
        var calls: [String: String] = [:]

        func call(_ function: String, _ parameters: [MoodleParameter] = []) async -> JSON? {
            do {
                let value: JSON = try await client.call(function, parameters)
                calls[function] = "ok"
                return value
            } catch {
                calls[function] = Redactor.redact(String(describing: error))
                return nil
            }
        }

        let info = await call("core_webservice_get_site_info")
        let userId = info?["userid"]?.int ?? 0
        report["functions"] = (info?["functions"]?.array ?? []).compactMap { $0["name"]?.string }.sorted()

        let courses = overview.courses.filter { $0.source == .moodle && $0.active }
        let ids = courses.compactMap { Int($0.externalId) }
        let forums = await call("mod_forum_get_forums_by_courses", [.ints("courseids", ids)])?.array ?? []
        let pages = await call("mod_page_get_pages_by_courses", [.ints("courseids", ids)])?["pages"]?.array ?? []
        let books = await call("mod_book_get_books_by_courses", [.ints("courseids", ids)])?["books"]?.array ?? []
        let quizzes = await call("mod_quiz_get_quizzes_by_courses", [.ints("courseids", ids)])?["quizzes"]?.array ?? []
        let assigns = await call("mod_assign_get_assignments", [.ints("courseids", ids)])?["courses"]?.array ?? []
        let labels = await call("mod_label_get_labels_by_courses", [.ints("courseids", ids)])?["labels"]?.array ?? []
        let events = await call("core_calendar_get_calendar_events", [
            .ints("events[courseids]", ids), .int("options[timestart]", Int(Date.now.timeIntervalSince1970) - 60 * 86_400),
            .int("options[timeend]", Int(Date.now.timeIntervalSince1970) + 200 * 86_400), .int("options[userevents]", 1),
            .int("options[siteevents]", 1),
        ])?["events"]?.array ?? []
        let notifications = await call("message_popup_get_popup_notifications", [
            .int("useridto", userId), .int("limit", 50), .int("offset", 0),
        ])?["notifications"]?.array ?? []
        report["notifications"] = [
            "count": notifications.count,
            "unread": notifications.filter { $0["read"]?.bool == false }.count,
            "components": Dictionary(grouping: notifications, by: { $0["component"]?.string ?? "?" }).mapValues(\.count),
            "subjects": notifications.prefix(15).compactMap { $0["subject"]?.string },
        ]
        let messages = await call("core_message_get_conversations", [.int("userid", userId), .int("limitnum", 20)])?["conversations"]?.array ?? []
        report["conversations"] = messages.count

        var perCourse: [[String: Any]] = []
        for course in courses {
            guard let moodleId = Int(course.externalId) else { continue }
            var entry: [String: Any] = ["course": course.shortName, "moodleId": moodleId]

            // Imported now
            let mine = { (items: [PortalOverview.ItemRow]) in items.filter { $0.courseId == course.id }.count }
            entry["imported"] = [
                "deadlines": mine(overview.openDeadlines + overview.doneDeadlines),
                "announcements": mine(overview.announcements),
                "materials": mine(overview.materials),
            ]

            // Course page: sections, their summaries, every module type
            let sections = await call("core_course_get_contents", [.int("courseid", moodleId)])?.array ?? []
            var modules: [String: [String]] = [:]
            var described = 0
            var moduleFiles = 0
            for section in sections {
                for module in section["modules"]?.array ?? [] {
                    let name = module["modname"]?.string ?? "?"
                    modules[name, default: []].append(module["name"]?.string ?? "")
                    if !(module["description"]?.string ?? "").isEmpty { described += 1 }
                    moduleFiles += (module["contents"]?.array ?? []).filter { $0["type"]?.string == "file" }.count
                }
            }
            entry["sections"] = sections.count
            entry["sectionsWithSummary"] = sections.filter { HTMLText.plainText($0["summary"]?.string ?? "").count > 20 }.count
            entry["modules"] = modules.mapValues { ["count": $0.count, "names": Array($0.prefix(6))] }
            entry["modulesWithDescription"] = described
            entry["filesInModules"] = moduleFiles

            // Forums: every forum, its discussions and replies
            var forumRows: [[String: Any]] = []
            for forum in forums where forum["course"]?.int == moodleId {
                let id = forum["id"]?.int ?? 0
                let discussions = await call("mod_forum_get_forum_discussions",
                                             [.int("forumid", id), .int("page", 0), .int("perpage", 100)])?["discussions"]?.array ?? []
                forumRows.append([
                    "name": forum["name"]?.string ?? "", "type": forum["type"]?.string ?? "",
                    "discussions": discussions.count,
                    "replies": discussions.compactMap { $0["numreplies"]?.int }.reduce(0, +),
                    "withAttachments": discussions.filter { $0["attachment"]?.bool == true || !($0["attachments"]?.array ?? []).isEmpty }.count,
                ])
            }
            entry["forums"] = forumRows

            entry["pages"] = pages.filter { $0["course"]?.int == moodleId }
                .map { ["name": $0["name"]?.string ?? "", "chars": HTMLText.plainText($0["content"]?.string ?? "").count] }
            entry["books"] = books.filter { $0["course"]?.int == moodleId }.compactMap { $0["name"]?.string }
            entry["labelsWithText"] = labels.filter { $0["course"]?.int == moodleId && HTMLText.plainText($0["intro"]?.string ?? "").count > 10 }.count
            entry["quizzes"] = quizzes.filter { $0["course"]?.int == moodleId }
                .map { ["name": $0["name"]?.string ?? "", "timeclose": $0["timeclose"]?.int ?? 0] }
            let courseAssigns = assigns.first { $0["id"]?.int == moodleId }?["assignments"]?.array ?? []
            entry["assignments"] = courseAssigns.map {
                ["name": $0["name"]?.string ?? "", "duedate": $0["duedate"]?.int ?? 0,
                 "introChars": HTMLText.plainText($0["intro"]?.string ?? "").count,
                 "attachments": ($0["introattachments"]?.array ?? []).count]
            }
            let courseEvents = events.filter { $0["courseid"]?.int == moodleId }
            entry["calendarEvents"] = Dictionary(grouping: courseEvents, by: { "\($0["eventtype"]?.string ?? "?")/\($0["modulename"]?.string ?? "-")" }).mapValues(\.count)

            let grades = await call("gradereport_user_get_grade_items", [.int("courseid", moodleId), .int("userid", userId)])
            let items = grades?["usergrades"]?.array?.first?["gradeitems"]?.array ?? []
            entry["gradeItems"] = items.count
            entry["gradedItems"] = items.filter { $0["graderaw"]?.double != nil }.count

            let completion = await call("core_completion_get_activities_completion_status", [.int("courseid", moodleId), .int("userid", userId)])
            entry["completionTracked"] = completion?["statuses"]?.array?.count ?? 0

            let summary = await call("core_course_get_courses_by_field", [.value("field", "id"), .value("value", String(moodleId))])
            entry["courseSummaryChars"] = HTMLText.plainText(summary?["courses"]?.array?.first?["summary"]?.string ?? "").count
            perCourse.append(entry)
        }
        report["courses"] = perCourse
        report["calls"] = calls

        let folder = FileManager.default.temporaryDirectory.appending(path: "audit", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appending(path: "moodle.json"))
        }
        NSApp.terminate(nil)
    }
}

/// Any JSON value, for looking around in responses without a model for each.
enum JSON: Decodable {
    case object([String: JSON]), array([JSON]), string(String), number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSON].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSON].self)) }
    }

    subscript(key: String) -> JSON? { if case .object(let object) = self { object[key] } else { nil } }
    var array: [JSON]? { if case .array(let value) = self { value } else { nil } }
    var string: String? { if case .string(let value) = self { value } else { nil } }
    var double: Double? { if case .number(let value) = self { value } else { nil } }
    var int: Int? { double.map { Int($0) } }
    var bool: Bool? {
        switch self {
        case .bool(let value): value
        case .number(let value): value != 0
        default: nil
        }
    }
}
