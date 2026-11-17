import Foundation
import GRDB

/// Everything Solve remembers about a course, ready to read or to hand to the model.
public struct MemoryDocument: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var itemId: Int64
        public var title: String
        public var section: String?
        public var digest: String
        public var edited: Bool
        public var changedSinceEdit: Bool
    }
    public struct Unread: Sendable, Equatable {
        public var title: String
        public var reason: String
    }
    public var notes: String
    public var overview: String
    public var files: [Entry]
    public var unread: [Unread]
}

/// What the course page shows about a memory: which course holds it, how many files it has read,
/// and when it last changed.
public struct MemorySummary: Sendable, Equatable {
    /// The course the notes and the overview are saved under.
    public var memoryCourseId: Int64
    public var files: Int
    public var updatedAt: Date
}

extension CourseMemory {
    /// Notes, overview and the digest of every PDF in lecture order, plus the files Solve cannot read.
    public func document(memoryCourseId: Int64, courseIds: [Int64]) throws -> MemoryDocument {
        let ids = courseIds.map(String.init).joined(separator: ",")
        let (record, rows) = try database.writer.read { db -> (CourseMemoryRecord?, [Row]) in
            let rows = try Row.fetchAll(db, sql: """
                SELECT i.id, i.title, m.digest, m.edited, m.sha256 AS memory_sha, x.sha256 AS index_sha
                FROM uni_memory_file m
                JOIN uni_item i ON i.id = m.item_id
                LEFT JOIN uni_index x ON x.item_id = i.id
                WHERE m.course_id IN (\(ids)) AND i.deleted_at IS NULL AND m.digest != ''
                ORDER BY i.position IS NULL, i.position, COALESCE(i.starts_at, i.due_at, i.first_seen_at), i.id
                """)
            return (try CourseMemoryRecord.fetchOne(db, key: memoryCourseId), rows)
        }
        let files = rows.map { row -> MemoryDocument.Entry in
            let edited: Bool = row["edited"]
            let memorySha: String? = row["memory_sha"]
            let indexSha: String? = row["index_sha"]
            return MemoryDocument.Entry(itemId: row["id"], title: row["title"], section: nil, digest: row["digest"],
                                        edited: edited, changedSinceEdit: edited && indexSha != nil && memorySha != indexSha)
        }
        return MemoryDocument(notes: record?.notes ?? "", overview: record?.overview ?? "", files: files,
                              unread: try unread(courseIds: courseIds).map { .init(title: $0.title, reason: $0.reason) })
    }

    /// The memory of these related courses, or nil when Solve hasn't built one yet. The notes and
    /// overview belong to the first of `courseIds` that has them (Solve keys them on the
    /// assignment's course, which may be a related one), else to the first id.
    public func summary(courseIds: [Int64]) throws -> MemorySummary? {
        guard let first = courseIds.first else { return nil }
        let ids = courseIds.map(String.init).joined(separator: ",")
        return try database.writer.read { db in
            let records = try CourseMemoryRecord.fetchAll(db, sql: "SELECT * FROM uni_memory WHERE course_id IN (\(ids))")
            let record = courseIds.lazy.compactMap { id in records.first { $0.courseId == id } }.first
            let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS files, MAX(m.updated_at) AS updated FROM uni_memory_file m
                JOIN uni_item i ON i.id = m.item_id
                WHERE m.course_id IN (\(ids)) AND i.deleted_at IS NULL AND m.digest != ''
                """)
            let files: Int = row?["files"] ?? 0
            let fileUpdate: Date? = row?["updated"]
            guard record != nil || files > 0 else { return nil }
            let updated = [record?.updatedAt, fileUpdate].compactMap { $0 }.max() ?? .distantPast
            return MemorySummary(memoryCourseId: record?.courseId ?? first, files: files, updatedAt: updated)
        }
    }

    /// The document as text for the model. Over budget, digests of files not in `relevant` go first
    /// (from the end), then relevant ones. Notes and overview always stay.
    public static func text(_ document: MemoryDocument, keeping relevant: [Int64], budget: Int = 120_000) -> String {
        func render(_ files: [MemoryDocument.Entry]) -> String {
            var parts = ["## Your notes\n\(document.notes)", "## Course overview\n\(document.overview)"]
            for file in files {
                let heading = file.section.map { $0.isEmpty ? file.title : "\(file.title) (\($0))" } ?? file.title
                parts.append("## \(heading)\n\(file.digest)")
            }
            return parts.joined(separator: "\n\n")
        }
        var files = document.files
        var text = render(files)
        for keep in [false, true] {
            while text.count > budget, let index = files.lastIndex(where: { relevant.contains($0.itemId) == keep }) {
                files.remove(at: index)
                text = render(files)
            }
        }
        return text
    }
}
