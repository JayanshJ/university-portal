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
