import Foundation
import GRDB

/// Everything the current views show, read in one transaction and re-read after every change.
public struct PortalOverview: Sendable, Equatable {
    public struct SourceRow: Sendable, Equatable {
        public var status: SourceStatus
        public var lastSyncAt: Date?
        public var lastError: String?
    }

    public struct CourseRow: Sendable, Equatable, Identifiable {
        public var id: Int64
        public var source: SourceKind
        public var externalId: String
        public var shortName: String
        public var fullName: String
        public var active: Bool
        public var isOverridden: Bool
        /// The term named in the course's name, e.g. "SoSe 26".
        public var term: String?
        public var termIsPast: Bool
    }

    public struct ItemRow: Sendable, Equatable, Identifiable, Hashable {
        public var id: Int64
        public var kind: ItemKind
        public var source: SourceKind
        public var courseId: Int64
        public var course: String
        public var courseFullName: String
        public var title: String
        /// Due date for deadlines, posting date for announcements, start for events, last change for materials.
        public var date: Date?
        public var url: String?
        /// Section (materials), calendar category (events), module type (deadlines) or author (announcements).
        public var section: String?
        public var isRead: Bool
        public var firstSeenAt: Date
        public var hasFile: Bool
        public var isCached: Bool
        public var filename: String?
        public var endDate: Date?
        public var location: String?
        public var allDay: Bool
        public var isExam: Bool
        public var doneAt: Date?
        public var doneSource: DoneSource?
        public var dueChangedAt: Date?
        /// Plain text of an announcement's body.
        public var body: String?

        /// Unread and not part of a course's first import.
        public var isNew: Bool { !isRead }

        init(_ item: UniItem, course: UniCourse, source: SourceKind, hasFile: Bool, isCached: Bool, filename: String? = nil) {
            id = item.id!
            kind = item.kind
            self.source = source
            courseId = item.courseId
            self.course = course.shortName
            courseFullName = course.fullName
            title = item.title
            date = switch item.kind {
            case .deadline: item.dueAt
            case .announcement, .event: item.startsAt
            case .material: item.updatedAt
            }
            url = item.url
            section = item.category
            isRead = item.readAt != nil
            firstSeenAt = item.firstSeenAt
            self.hasFile = hasFile
            self.isCached = isCached
            self.filename = filename
            endDate = item.endsAt
            location = item.location
            allDay = item.allDay
            isExam = item.isExam
            doneAt = item.doneAt
            doneSource = item.doneSource
            dueChangedAt = item.dueChangedAt
            body = item.kind == .announcement ? item.bodyHtml.map(HTMLText.plainText) : nil
        }
    }

    public struct RunRow: Sendable, Equatable, Identifiable {
        public var id: Int64
        public var job: String
        public var startedAt: Date
        public var ok: Bool?
        public var counts: [String: Int]?
        public var error: String?
    }

    public var moodle: SourceRow?
    public var cms: SourceRow?
    public var diagnostics: MoodleDiagnostics?
    public var courses: [CourseRow] = []
    public var openDeadlines: [ItemRow] = []
    /// Done in the last 30 days, newest first.
    public var doneDeadlines: [ItemRow] = []
    public var announcements: [ItemRow] = []
    public var materials: [ItemRow] = []
    /// CMS calendar events from today on, for three weeks, without hidden categories.
    public var upcomingEvents: [ItemRow] = []
    public var recentRuns: [RunRow] = []
    public var lastVisitAt: Date?
    public var pdfDarkPages = false

    public init() {}

    public var needsReconnect: Bool {
        moodle?.status == .needsReconnect || cms?.status == .needsReconnect
    }

    /// Unread announcements and materials that arrived after the last visit to Today.
    public var newSinceVisit: (announcements: [ItemRow], materials: [ItemRow]) {
        let since = lastVisitAt ?? .distantPast
        return (announcements.filter { $0.isNew && $0.firstSeenAt > since },
                materials.filter { $0.isNew && $0.firstSeenAt > since })
    }

    static func fetch(_ db: Database) throws -> PortalOverview {
        var overview = PortalOverview()
        let sources = try UniSource.fetchAll(db)
        for source in sources {
            let row = SourceRow(status: source.status, lastSyncAt: source.lastSyncAt, lastError: source.lastError)
            switch source.kind {
            case .moodle: overview.moodle = row
            case .cms: overview.cms = row
            }
        }
        let kindBySource = Dictionary(uniqueKeysWithValues: sources.compactMap { s in s.id.map { ($0, s.kind) } })
        overview.diagnostics = try UniDatabase.state(db, .moodleDiagnostics, as: MoodleDiagnostics.self)
        overview.lastVisitAt = try UniDatabase.state(db, .lastVisitAt, as: Date.self)
        overview.pdfDarkPages = try UniDatabase.state(db, .pdfDarkPages, as: Bool.self) ?? false

        let courses = try UniCourse.order(Column("active").desc, Column("short_name")).fetchAll(db)
        let courseById = Dictionary(uniqueKeysWithValues: courses.compactMap { c in c.id.map { ($0, c) } })
        let currentTerm = AcademicTerm.current()
        overview.courses = courses.compactMap { course in
            let term = AcademicTerm.parse("\(course.shortName) \(course.fullName)")
            return course.id.map {
                CourseRow(id: $0, source: kindBySource[course.sourceId] ?? .moodle, externalId: course.externalId,
                          shortName: course.shortName, fullName: course.fullName,
                          active: course.active, isOverridden: course.activeOverride != nil,
                          term: term?.label, termIsPast: term.map { $0 < currentTerm } ?? false)
            }
        }

        let activeIds = courses.filter(\.active).compactMap(\.id)
        let files = Dictionary(uniqueKeysWithValues: try UniFile.fetchAll(db).map { ($0.itemId, $0) })

        func rows(_ kind: ItemKind, _ request: QueryInterfaceRequest<UniItem>) throws -> [ItemRow] {
            try request
                .filter(Column("kind") == kind.rawValue && Column("deleted_at") == nil
                        && activeIds.contains(Column("course_id")))
                .fetchAll(db)
                .compactMap { item in
                    guard let course = courseById[item.courseId] else { return nil }
                    let file = files[item.id!]
                    return ItemRow(item, course: course, source: kindBySource[course.sourceId] ?? .moodle,
                                   hasFile: file != nil, isCached: file?.localPath != nil, filename: file?.filename)
                }
        }

        overview.openDeadlines = try rows(.deadline, UniItem.filter(Column("done_at") == nil).order(Column("due_at")))
        overview.doneDeadlines = try rows(.deadline, UniItem
            .filter(Column("done_at") != nil && Column("done_at") > Date.now.addingTimeInterval(-30 * 86_400))
            .order(Column("done_at").desc))
        overview.announcements = try rows(.announcement, UniItem.order(Column("starts_at").desc))
        overview.materials = try rows(.material, UniItem.order(Column("course_id"), Column("id")))

        let startOfToday = Calendar.current.startOfDay(for: .now)
        overview.upcomingEvents = try rows(.event, UniItem
            .filter(Column("starts_at") >= startOfToday && Column("starts_at") < startOfToday.addingTimeInterval(21 * 86_400))
            .order(Column("starts_at")))
            .filter { row in !(row.section.map { courseById[row.courseId]?.hiddenCategories.contains($0) ?? false } ?? false) }

        overview.recentRuns = try UniSyncRun.order(Column("started_at").desc).limit(10).fetchAll(db).map {
            RunRow(id: $0.id!, job: $0.job, startedAt: $0.startedAt, ok: $0.ok, counts: $0.counts, error: $0.error)
        }
        return overview
    }
}

extension UniDatabase {
    /// A fresh overview now and after every committed change.
    public func overviewUpdates() -> AsyncThrowingStream<PortalOverview, Error> {
        let values = ValueObservation.tracking(PortalOverview.fetch).values(in: writer)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await overview in values { continuation.yield(overview) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
