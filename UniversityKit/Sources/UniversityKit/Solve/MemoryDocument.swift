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
