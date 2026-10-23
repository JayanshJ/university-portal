import Foundation
import GRDB

/// Builds the page index for "Ask your materials": downloads each PDF of an active course if needed,
/// extracts its text per page, and stores the chunks in `uni_page` (full-text indexed). A PDF whose
/// file changed is re-indexed; one that is already indexed is skipped.
public actor MaterialIndexer {
    public struct Progress: Sendable, Equatable {
        public var done = 0
        public var total = 0
        public var failed = 0
        public var current: String?
        public var isRunning = false

        public init() {}

        init(total: Int, isRunning: Bool) {
            self.total = total
            self.isRunning = isRunning
        }
    }

    public struct Status: Sendable, Equatable {
        public var indexed: Int
        public var total: Int
        public var pages: Int

        public init(indexed: Int, total: Int, pages: Int) {
            self.indexed = indexed
            self.total = total
            self.pages = pages
        }
    }

    /// Larger files are skipped (scans and book dumps rarely have useful text per MB).
    static let maxBytes: Int64 = 80 * 1_024 * 1_024

    let database: UniDatabase
    let files: MaterialFiles

    private static let log = Log(category: "index")

    public init(database: UniDatabase, files: MaterialFiles) {
        self.database = database
        self.files = files
    }

    /// PDFs of active courses and how many are indexed.
    public nonisolated func status() throws -> Status {
        try database.writer.read { db in
            let total = try Int.fetchOne(db, sql: "SELECT count(*) FROM (\(Self.pdfQuery))") ?? 0
            let indexed = try Int.fetchOne(db, sql: """
                SELECT count(*) FROM (\(Self.pdfQuery)) pdf
                JOIN uni_index x ON x.item_id = pdf.id AND x.error IS NULL
                """) ?? 0
            let pages = try Int.fetchOne(db, sql: "SELECT coalesce(sum(pages), 0) FROM uni_index WHERE error IS NULL") ?? 0
            return Status(indexed: indexed, total: total, pages: pages)
        }
    }

    /// How many PDFs wait to be indexed, and how much of them still has to be downloaded.
    public nonisolated func pendingSummary() throws -> (count: Int, downloadBytes: Int64) {
        try database.writer.read { db in
            let pending = try Self.pending(db)
            guard !pending.isEmpty else { return (0, 0) }
            let ids = pending.map(\.id)
            let bytes = try Int64.fetchOne(db, sql: """
                SELECT coalesce(sum(size_bytes), 0) FROM uni_file
                WHERE local_path IS NULL AND item_id IN (\(ids.map { _ in "?" }.joined(separator: ",")))
                """, arguments: StatementArguments(ids)) ?? 0
            return (pending.count, bytes)
        }
    }

    /// Indexes every PDF that is new or changed; `onProgress` is called after each file.
    @discardableResult
    public func run(onProgress: @Sendable (Progress) -> Void = { _ in }) async -> Progress {
        let pending = (try? await database.writer.read { db in try Self.pending(db) }) ?? []
        var progress = Progress(total: pending.count, isRunning: true)
        onProgress(progress)

        for item in pending {
            if Task.isCancelled { break }
            progress.current = item.filename
            onProgress(progress)
            do {
                let url = try await files.open(itemId: item.id, markRead: false)
                let chunks = try await Task.detached(priority: .utility) {
                    guard let pages = PageText.pages(of: url) else { throw IndexError.notReadable }
                    return (PageText.chunks(pages: pages), pages.count)
                }.value
                let sha = try await database.writer.read { db in
                    try String.fetchOne(db, sql: "SELECT sha256 FROM uni_file WHERE item_id = ?", arguments: [item.id])
                }
                try await store(itemId: item.id, chunks: chunks.0, pageCount: chunks.1, sha256: sha, error: nil)
            } catch {
                progress.failed += 1
                Self.log.warning("Could not index \(item.filename): \(error)")
                try? await store(itemId: item.id, chunks: [], pageCount: 0, sha256: nil,
                                 error: Redactor.redact(String(describing: error)))
            }
            progress.done += 1
            onProgress(progress)
        }
        progress.current = nil
        progress.isRunning = false
        onProgress(progress)
        return progress
    }

    enum IndexError: Error { case notReadable }

    private func store(itemId: Int64, chunks: [PageChunk], pageCount: Int, sha256: String?, error: String?) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM uni_page WHERE item_id = ?", arguments: [itemId])
            for chunk in chunks {
                try db.execute(sql: "INSERT INTO uni_page (item_id, page, ordinal, text) VALUES (?, ?, ?, ?)",
                               arguments: [itemId, chunk.page, chunk.ordinal, chunk.text])
            }
            try db.execute(sql: """
                INSERT INTO uni_index (item_id, sha256, pages, chunks, indexed_at, error) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(item_id) DO UPDATE SET sha256 = excluded.sha256, pages = excluded.pages,
                    chunks = excluded.chunks, indexed_at = excluded.indexed_at, error = excluded.error
                """, arguments: [itemId, sha256, pageCount, chunks.count, Date.now, error])
        }
    }

    /// Live PDF materials of active courses.
    static let pdfQuery = """
        SELECT i.id, f.filename, f.sha256, f.size_bytes FROM uni_item i
        JOIN uni_file f ON f.item_id = i.id
        JOIN uni_course c ON c.id = i.course_id
        WHERE i.kind = 'material' AND i.deleted_at IS NULL AND c.active = 1 AND lower(f.filename) LIKE '%.pdf'
        """

    /// Not yet indexed, changed since indexing (a new download has a different hash), or failed before.
    static func pending(_ db: Database) throws -> [(id: Int64, filename: String)] {
        try Row.fetchAll(db, sql: """
            SELECT pdf.id, pdf.filename FROM (\(pdfQuery)) pdf
            LEFT JOIN uni_index x ON x.item_id = pdf.id
            WHERE coalesce(pdf.size_bytes, 0) <= ?
              AND (x.item_id IS NULL OR x.error IS NOT NULL
                   OR (pdf.sha256 IS NOT NULL AND x.sha256 IS NOT pdf.sha256))
            ORDER BY pdf.id
            """, arguments: [maxBytes]).map { ($0["id"], $0["filename"]) }
    }
}
