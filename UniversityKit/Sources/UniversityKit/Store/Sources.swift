import Foundation
import GRDB

extension UniDatabase {
    /// The source row for `kind`, created on first use.
    public func source(_ kind: SourceKind) throws -> UniSource {
        try writer.write { db in try Self.source(db, kind) }
    }

    static func source(_ db: Database, _ kind: SourceKind) throws -> UniSource {
        if let existing = try UniSource.filter(Column("kind") == kind.rawValue).fetchOne(db) {
            return existing
        }
        var source = UniSource(kind: kind)
        try source.insert(db)
        return source
    }

    public func setStatus(_ kind: SourceKind, _ status: SourceStatus, error: String? = nil, syncedAt: Date? = nil) throws {
        try writer.write { db in
            var source = try Self.source(db, kind)
            source.status = status
            source.lastError = error
            if let syncedAt { source.lastSyncAt = syncedAt }
            try source.update(db)
        }
    }

    /// Hides or shows one calendar category (e.g. "Tutorial") of a course in the schedule.
    public func setCategory(_ category: String, hidden: Bool, courseId: Int64) throws {
        try writer.write { db in
            guard var course = try UniCourse.fetchOne(db, key: courseId) else { return }
            var categories = Set(course.hiddenCategories)
            if hidden { categories.insert(category) } else { categories.remove(category) }
            course.hiddenCategories = categories.sorted()
            try course.update(db)
        }
    }

    /// The calendar categories each course has, for the "hide a category" menu.
    public func eventCategories() throws -> [Int64: [String]] {
        try writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT course_id, category FROM uni_item
                WHERE kind = 'event' AND category IS NOT NULL AND deleted_at IS NULL ORDER BY category
                """)
            return Dictionary(grouping: rows, by: { $0["course_id"] as Int64 }).mapValues { $0.map { $0["category"] } }
        }
    }

    public func hiddenCategories(courseId: Int64) throws -> Set<String> {
        try writer.read { db in Set(try UniCourse.fetchOne(db, key: courseId)?.hiddenCategories ?? []) }
    }

    /// The user's choice wins over the automatic value; nil goes back to automatic.
    public func setCourseActive(id: Int64, override: Bool?) throws {
        try writer.write { db in
            guard var course = try UniCourse.fetchOne(db, key: id) else { return }
            course.activeOverride = override
            course.active = override ?? course.autoActive
            try course.update(db)
        }
    }
}
