import Foundation
import GRDB

/// The two Moodle jobs: `moodle.fast` (courses, deadlines, announcements) and `moodle.materials`.
public struct MoodleSync: Sendable {
    let database: UniDatabase
    let client: MoodleClient
    let now: @Sendable () -> Date

    private static let log = Log(category: "moodle")

    public init(database: UniDatabase, client: MoodleClient, now: @escaping @Sendable () -> Date = { .now }) {
        self.database = database
        self.client = client
        self.now = now
    }

    public func siteInfo() async throws -> MoodleSiteInfo {
        do {
            return try await client.call("core_webservice_get_site_info")
        } catch MoodleError.moodle(errorcode: "accessexception", _) {
            throw MoodleError.invalidToken
        }
    }

    public func runFast() async throws -> SyncOutcome {
        let now = now()
        let info = try await siteInfo()
        try database.updateState(.moodleDiagnostics, default: MoodleDiagnostics()) {
            $0.canSubmitAssignments = info.canSubmitAssignments
        }
        let source = try database.source(.moodle)
        let sourceId = source.id!

        // 1–2. Courses
        let courses: [MoodleCourse] = try await client.call(
            "core_enrol_get_users_courses", [.int("userid", info.userid)])
        let inputs = courses.map { course in
            let shortName = HTMLText.decodeEntities(course.shortname)
            let fullName = HTMLText.decodeEntities(course.fullname)
            return CourseInput(
                externalId: String(course.id),
                shortName: shortName,
                fullName: fullName,
                url: client.siteURL.appending(path: "course/view.php")
                    .appending(queryItems: [URLQueryItem(name: "id", value: String(course.id))]).absoluteString,
                active: Self.isActive(name: "\(shortName) \(fullName)", enddate: course.enddate, now: now))
        }
        let courseIds = try await database.writer.write { db in
            try Upserter.upsertCourses(db, sourceId: sourceId, inputs)
        }
        let activeCourses = try await database.writer.read { db in
            try UniCourse.filter(Column("source_id") == sourceId && Column("active") == true).fetchAll(db)
        }
        let activeMoodleIds = activeCourses.compactMap { Int($0.externalId) }

        // 3. Deadlines: assignments and anything else actionable, then other activities' closing dates
        var deadlines = try await fetchDeadlines(courseIds: courseIds, activeMoodleIds: activeMoodleIds, now: now)
        deadlines += try await fetchActivityDeadlines(
            courseIds: courseIds, activeMoodleIds: activeMoodleIds,
            from: Int(now.timeIntervalSince1970) - 7 * 86_400, to: Int(now.timeIntervalSince1970) + 120 * 86_400,
            known: Set(deadlines.map(\.externalId)))

        let allDeadlines = deadlines

        // 4. Every forum thread with its replies: announcements and discussions
        let threads = try await fetchThreads(courseIds: courseIds, activeMoodleIds: activeMoodleIds)
        let (announcements, discussions) = threadItems(threads)

        // 5. Grades
        let grades = try await fetchGrades(courses: activeCourses, userId: info.userid)

        let outcome = try await database.writer.write { db in
            let deadlineScope = Set(courseIds.values)
            let activeScope = Set(activeCourses.compactMap(\.id))
            return try Upserter.apply(db, kind: .deadline, courseIds: deadlineScope, items: allDeadlines, now: now)
                + Upserter.apply(db, kind: .announcement, courseIds: activeScope, items: announcements, now: now)
                + Upserter.apply(db, kind: .discussion, courseIds: activeScope, items: discussions, now: now)
                + Upserter.apply(db, kind: .grade, courseIds: activeScope, items: grades, now: now)
        }

        // 6. Direct messages
        _ = try await syncConversations(userId: info.userid, sourceId: sourceId)
        return outcome
    }

    public func runMaterials() async throws -> SyncOutcome {
        let now = now()
        _ = try await siteInfo()  // health check, so a dead token stops the run here
        let sourceId = try database.source(.moodle).id!
        let activeCourses = try await database.writer.read { db in
            try UniCourse.filter(Column("source_id") == sourceId && Column("active") == true).fetchAll(db)
        }

        var items: [ItemInput] = []
        var sectionsByCourse: [Int64: [MoodleSection]] = [:]
        for course in activeCourses {
            guard let moodleId = Int(course.externalId), let courseId = course.id else { continue }
            let sections: [MoodleSection] = try await client.call(
                "core_course_get_contents", [.int("courseid", moodleId)])
            sectionsByCourse[courseId] = sections
            items += Self.materials(from: sections, courseId: courseId)
        }
        // Files attached to assignments and forum posts, and the text on each course page.
        let page = try await coursePage(courses: activeCourses, sectionsByCourse: sectionsByCourse)
        let courseIds = Dictionary(uniqueKeysWithValues: activeCourses.compactMap { course in course.id.map { (course.externalId, $0) } })
        let threads = try await fetchThreads(courseIds: courseIds, activeMoodleIds: activeCourses.compactMap { Int($0.externalId) })
        // A course whose page came back empty keeps the zero-results guard: no other files for it either.
        let emptyPages = Set(sectionsByCourse.filter { $0.value.isEmpty }.keys)
        items += (page.files + threadMaterials(threads)).filter { !emptyPages.contains($0.courseId) }
        let found = items
        let notes = page.notes

        return try await database.writer.write { db in
            let scope = Set(activeCourses.compactMap(\.id))
            return try Upserter.apply(db, kind: .material, courseIds: scope, items: found, now: now)
                + Upserter.apply(db, kind: .note, courseIds: scope, items: notes, now: now)
        }
    }

    // MARK: - Calls

    private func fetchDeadlines(courseIds: [String: Int64], activeMoodleIds: [Int], now: Date) async throws -> [ItemInput] {
        let from = Int(now.timeIntervalSince1970) - 7 * 86_400
        let to = Int(now.timeIntervalSince1970) + 120 * 86_400
        do {
            let response: MoodleActionEvents = try await client.call(
                "core_calendar_get_action_events_by_timesort",
                [.int("timesortfrom", from), .int("timesortto", to), .int("limitnum", 50)])
            try recordDeadlinesMode(.actionEvents, reason: nil)
            return response.events.compactMap { event in
                guard let courseId = event.course.flatMap({ courseIds[String($0.id)] }) else { return nil }
                return ItemInput(
                    courseId: courseId, kind: .deadline, externalId: String(event.id),
                    title: Self.deadlineTitle(event.name),
                    dueAt: Date(timeIntervalSince1970: TimeInterval(event.timesort)),
                    url: event.url, category: event.modulename)
            }
        } catch MoodleError.moodle(let code, let message) {
            // Refused with the token: fall back to assignment due dates.
            Self.log.warning("Action events refused (\(code)): \(message). Using mod_assign_get_assignments.")
            try recordDeadlinesMode(.assignFallback, reason: "\(code): \(message)")
            let response: MoodleAssignments = try await client.call(
                "mod_assign_get_assignments", [.ints("courseids", activeMoodleIds)])
            return response.courses.flatMap { course -> [ItemInput] in
                guard let courseId = courseIds[String(course.id)] else { return [] }
                return course.assignments.compactMap { assignment in
                    guard assignment.duedate > 0, (from...to).contains(assignment.duedate) else { return nil }
                    return ItemInput(
                        courseId: courseId, kind: .deadline, externalId: "assign:\(assignment.cmid)",
                        title: HTMLText.decodeEntities(assignment.name),
                        dueAt: Date(timeIntervalSince1970: TimeInterval(assignment.duedate)),
                        url: client.siteURL.appending(path: "mod/assign/view.php")
                            .appending(queryItems: [URLQueryItem(name: "id", value: String(assignment.cmid))])
                            .absoluteString,
                        category: "assign")
                }
            }
        }
    }

    private func recordDeadlinesMode(_ mode: MoodleDiagnostics.DeadlinesMode, reason: String?) throws {
        try database.updateState(.moodleDiagnostics, default: MoodleDiagnostics()) {
            $0.deadlinesMode = mode
            $0.deadlinesCheckedAt = now()
            $0.deadlinesFallbackReason = reason
        }
    }

    // MARK: - Normalizing

    /// A term in the name decides ("SoSe26" is past once WiSe 26/27 has begun). Without one, the
    /// end date does; Moodle often defaults it to a year after the start, so it is only a fallback.
    static func isActive(name: String, enddate: Int?, now: Date) -> Bool {
        if let term = AcademicTerm.parse(name) {
            return term >= AcademicTerm.current(at: now)
        }
        guard let enddate, enddate > 0 else { return true }
        return Date(timeIntervalSince1970: TimeInterval(enddate)) > now
    }

    /// "Blatt 3 ist fällig." → "Blatt 3"
    static func deadlineTitle(_ name: String) -> String {
        HTMLText.decodeEntities(name)
            .replacingOccurrences(of: #"\s+(ist fällig|is due|closes|schließt|endet|opens|öffnet)\.?$"#, with: "", options: .regularExpression)
    }

    /// Files of resource and folder modules, plus URL modules as link materials.
    static func materials(from sections: [MoodleSection], courseId: Int64) -> [ItemInput] {
        sections.flatMap { section in
            section.modules.flatMap { module -> [ItemInput] in
                let sectionName = HTMLText.decodeEntities(section.name)
                switch module.modname {
                case "resource", "folder":
                    return (module.contents ?? []).compactMap { content in
                        guard content.type == "file", let filename = content.filename,
                              let fileurl = content.fileurl else { return nil }
                        let path = content.filepath ?? "/"
                        return ItemInput(
                            courseId: courseId, kind: .material,
                            externalId: "\(module.id)\(path)\(filename)",
                            title: filename, url: module.url, category: sectionName,
                            file: FileInput(
                                filename: filename, mimetype: content.mimetype,
                                sizeBytes: content.filesize.map(Int64.init), remoteUrl: fileurl,
                                remoteModifiedAt: content.timemodified.map { Date(timeIntervalSince1970: TimeInterval($0)) }))
                    }
                case "url":
                    let target = module.contents?.first(where: { $0.type == "url" })?.fileurl ?? module.url
                    return [ItemInput(
                        courseId: courseId, kind: .material, externalId: "\(module.id)",
                        title: HTMLText.decodeEntities(module.name), url: target, category: sectionName)]
                default:
                    return []
                }
            }
        }
    }
}
