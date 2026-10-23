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
        public var shortName: String
        public var fullName: String
        public var active: Bool
        public var isOverridden: Bool
        /// The term named in the course's name, e.g. "SoSe 26".
        public var term: String?
        public var termIsPast: Bool
    }

    public struct ItemRow: Sendable, Equatable, Identifiable {
        public var id: Int64
        public var course: String
        public var title: String
        public var date: Date?
        public var url: String?
        public var section: String?
        public var isNew: Bool
        public var hasFile: Bool
        public var isCached: Bool
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
    public var diagnostics: MoodleDiagnostics?
    public var courses: [CourseRow] = []
    public var openDeadlines: [ItemRow] = []
    public var announcements: [ItemRow] = []
    public var materials: [ItemRow] = []
    public var recentRuns: [RunRow] = []

    public init() {}

    static func fetch(_ db: Database) throws -> PortalOverview {
        var overview = PortalOverview()
        if let source = try UniSource.filter(Column("kind") == SourceKind.moodle.rawValue).fetchOne(db) {
            overview.moodle = SourceRow(status: source.status, lastSyncAt: source.lastSyncAt, lastError: source.lastError)
        }
        overview.diagnostics = try UniDatabase.state(db, .moodleDiagnostics, as: MoodleDiagnostics.self)

        let courses = try UniCourse.order(Column("active").desc, Column("short_name")).fetchAll(db)
        let names = Dictionary(uniqueKeysWithValues: courses.compactMap { c in c.id.map { ($0, c.shortName) } })
        let currentTerm = AcademicTerm.current()
        overview.courses = courses.compactMap { course in
            let term = AcademicTerm.parse("\(course.shortName) \(course.fullName)")
            return course.id.map {
                CourseRow(id: $0, shortName: course.shortName, fullName: course.fullName,
                          active: course.active, isOverridden: course.activeOverride != nil,
                          term: term?.label, termIsPast: term.map { $0 < currentTerm } ?? false)
            }
        }

        let activeIds = courses.filter(\.active).compactMap(\.id)
        let lastVisit = try UniDatabase.state(db, .lastVisitAt, as: Date.self) ?? .distantPast
        let cached = try Set(Int64.fetchAll(db, sql: "SELECT item_id FROM uni_file WHERE local_path IS NOT NULL"))
        let withFile = try Set(Int64.fetchAll(db, sql: "SELECT item_id FROM uni_file"))

        func rows(_ kind: ItemKind, _ request: QueryInterfaceRequest<UniItem>, date: (UniItem) -> Date?) throws -> [ItemRow] {
            try request.filter(Column("kind") == kind.rawValue && Column("deleted_at") == nil).fetchAll(db).map { item in
                ItemRow(id: item.id!, course: names[item.courseId] ?? "", title: item.title, date: date(item),
                        url: item.url, section: item.category, isNew: item.firstSeenAt > lastVisit && item.readAt == nil,
                        hasFile: withFile.contains(item.id!), isCached: cached.contains(item.id!))
            }
        }

        overview.openDeadlines = try rows(.deadline, UniItem.filter(Column("done_at") == nil).order(Column("due_at")), date: \.dueAt)
        overview.announcements = try rows(.announcement, UniItem.filter(activeIds.contains(Column("course_id")))
            .order(Column("starts_at").desc), date: \.startsAt)
        overview.materials = try rows(.material, UniItem.filter(activeIds.contains(Column("course_id")))
            .order(Column("course_id"), Column("category"), Column("title")), date: \.updatedAt)

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
