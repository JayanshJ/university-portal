import CryptoKit
import Foundation
import GRDB

/// Solve's memory of a course: one ChatGPT digest per course PDF, cached by the file's fingerprint,
/// plus an overview over all digests. Digests and the overview can be edited by hand; edits are kept.
public struct CourseMemory: Sendable {
    public typealias Complete = @Sendable (_ instructions: String, _ input: String) async throws -> String

    public struct Progress: Sendable, Equatable {
        public var done: Int
        public var total: Int
        public var current: String?
        public var failed: [String]
        public init(done: Int = 0, total: Int = 0, current: String? = nil, failed: [String] = []) {
            self.done = done
            self.total = total
            self.current = current
            self.failed = failed
        }
    }

    let database: UniDatabase
    let complete: Complete
    let model: String

    public static let promptVersion = 1
    static let partSize = 60_000

    public init(database: UniDatabase, complete: @escaping Complete, model: String) {
        self.database = database
        self.complete = complete
        self.model = model
    }

    // MARK: Queries

    /// Live PDF materials of the given courses (active or not).
    private static func pdfQuery(_ courseIds: [Int64]) -> String {
        let ids = courseIds.map(String.init).joined(separator: ",")
        return """
            SELECT i.id, i.course_id, i.title, f.size_bytes FROM uni_item i
            JOIN uni_file f ON f.item_id = i.id
            WHERE i.kind = 'material' AND i.deleted_at IS NULL AND lower(f.filename) LIKE '%.pdf'
              AND i.course_id IN (\(ids))
            """
    }

    /// Files that wait for a digest: indexed without error, not edited by hand, and new, changed,
    /// from an older prompt or failed before.
    public func pending(courseIds: [Int64]) throws -> [(itemId: Int64, title: String)] {
        try database.writer.read { try Self.pending($0, courseIds: courseIds).map { ($0.id, $0.title) } }
    }

    private static func pending(_ db: Database, courseIds: [Int64]) throws -> [(id: Int64, courseId: Int64, title: String, sha256: String?)] {
        try Row.fetchAll(db, sql: """
            SELECT pdf.id, pdf.course_id, pdf.title, x.sha256 FROM (\(pdfQuery(courseIds))) pdf
            JOIN uni_index x ON x.item_id = pdf.id AND x.error IS NULL
            LEFT JOIN uni_memory_file m ON m.item_id = pdf.id
            WHERE m.item_id IS NULL
               OR (m.edited = 0 AND (m.sha256 IS NULL OR m.sha256 IS NOT x.sha256
                                     OR m.prompt_version < ? OR m.error IS NOT NULL))
            ORDER BY pdf.id
            """, arguments: [promptVersion]).map { ($0["id"], $0["course_id"], $0["title"], $0["sha256"]) }
    }

    /// Files Solve cannot read, with the reason.
    public func unread(courseIds: [Int64]) throws -> [(title: String, reason: String)] {
        try database.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT pdf.title, pdf.size_bytes, x.item_id AS indexed, x.error AS index_error, m.error AS digest_error
                FROM (\(Self.pdfQuery(courseIds))) pdf
                LEFT JOIN uni_index x ON x.item_id = pdf.id
                LEFT JOIN uni_memory_file m ON m.item_id = pdf.id
                ORDER BY pdf.id
                """).compactMap { row -> (String, String)? in
                let title: String = row["title"]
                if let error: String = row["index_error"] { return (title, error) }
                if row["indexed"] as Int64? == nil {
                    return (title, (row["size_bytes"] as Int64? ?? 0) > MaterialIndexer.maxBytes ? "too large" : "not indexed yet")
                }
                if let error: String = row["digest_error"] { return (title, error) }
                return nil
            }
        }
    }

    // MARK: Editing

    public func setNotes(_ notes: String, courseId: Int64) throws {
        try updateRecord(courseId) { $0.notes = notes }
    }

    public func setOverview(_ overview: String, courseId: Int64) throws {
        try updateRecord(courseId) { $0.overview = overview; $0.overviewEdited = true }
    }

    public func setDigest(_ digest: String, itemId: Int64) throws {
        try database.writer.write { db in
            try db.execute(sql: "UPDATE uni_memory_file SET digest = ?, edited = 1, updated_at = ? WHERE item_id = ?",
                           arguments: [digest, Date.now, itemId])
        }
    }

    /// Drops the hand edit and the fingerprint, so the next run reads the file again.
    public func reread(itemId: Int64) throws {
        try database.writer.write { db in
            try db.execute(sql: "UPDATE uni_memory_file SET edited = 0, sha256 = NULL WHERE item_id = ?", arguments: [itemId])
        }
    }

    /// Reads everything again. The user's notes stay.
    public func rebuild(memoryCourseId: Int64, courseIds: [Int64]) throws {
        try database.writer.write { db in
            let ids = courseIds.map(String.init).joined(separator: ",")
            try db.execute(sql: "UPDATE uni_memory_file SET sha256 = NULL, edited = 0 WHERE course_id IN (\(ids))")
            try db.execute(sql: "UPDATE uni_memory SET overview_edited = 0, overview_signature = NULL WHERE course_id = ?",
                           arguments: [memoryCourseId])
        }
    }

    private func updateRecord(_ courseId: Int64, _ change: (inout CourseMemoryRecord) -> Void) throws {
        try database.writer.write { db in
            var record = try CourseMemoryRecord.fetchOne(db, key: courseId) ?? CourseMemoryRecord(courseId: courseId)
            change(&record)
            record.updatedAt = .now
            try record.save(db)
        }
    }

    // MARK: Running

    /// Digests every pending file, drops rows of files that are gone, then rebuilds the overview if
    /// the digests changed. A file that fails is noted and skipped. Returns normally when cancelled.
    public func run(courseIds: [Int64], memoryCourseId: Int64, onProgress: @Sendable (Progress) -> Void) async -> Progress {
        var progress = Progress()
        guard !courseIds.isEmpty else { return progress }
        do {
            try await database.writer.write { db in
                try db.execute(sql: """
                    DELETE FROM uni_memory_file WHERE course_id IN (\(courseIds.map(String.init).joined(separator: ",")))
                      AND item_id NOT IN (SELECT id FROM (\(Self.pdfQuery(courseIds))))
                    """)
            }
            let todo = try await database.writer.read { try Self.pending($0, courseIds: courseIds) }
            progress.total = todo.count
            onProgress(progress)
            for file in todo {
                if Task.isCancelled { return progress }
                progress.current = file.title
                onProgress(progress)
                do {
                    let digest = try await digest(itemId: file.id, title: file.title)
                    try await database.writer.write { db in
                        let row = MemoryFile(itemId: file.id, courseId: file.courseId, sha256: file.sha256,
                                             promptVersion: Self.promptVersion, model: model, digest: digest)
                        try row.save(db)
                    }
                } catch {
                    if Task.isCancelled { return progress }
                    progress.failed.append(file.title)
                    let message = error.localizedDescription
                    try await database.writer.write { db in
                        if var row = try MemoryFile.fetchOne(db, key: file.id) {
                            row.error = message
                            try row.update(db)
                        } else {
                            try MemoryFile(itemId: file.id, courseId: file.courseId, promptVersion: Self.promptVersion,
                                           model: model, error: message).insert(db)
                        }
                    }
                }
                progress.done += 1
                onProgress(progress)
            }
            if Task.isCancelled { return progress }
            try await updateOverview(courseIds: courseIds, memoryCourseId: memoryCourseId)
        } catch {
            if !Task.isCancelled { progress.failed.append("Overview") }
        }
        progress.current = nil
        onProgress(progress)
        return progress
    }

    private func updateOverview(courseIds: [Int64], memoryCourseId: Int64) async throws {
        let (files, record) = try await database.writer.read { db -> ([(id: Int64, title: String, sha: String, digest: String)], CourseMemoryRecord?) in
            let rows = try Row.fetchAll(db, sql: """
                SELECT pdf.id, pdf.title, m.sha256, m.digest FROM (\(Self.pdfQuery(courseIds))) pdf
                JOIN uni_memory_file m ON m.item_id = pdf.id
                WHERE m.digest != '' ORDER BY pdf.id
                """)
            return (rows.map { ($0["id"], $0["title"], $0["sha256"] ?? "", $0["digest"]) },
                    try CourseMemoryRecord.fetchOne(db, key: memoryCourseId))
        }
        guard !files.isEmpty, record?.overviewEdited != true else { return }
        let signature = Self.hash(files.map { "\($0.id):\($0.sha)" }.sorted().joined(separator: "|") + "|v\(Self.promptVersion)")
        guard record?.overviewSignature != signature else { return }
        let input = files.map { "## \($0.title)\n\($0.digest)" }.joined(separator: "\n\n")
        let overview = try await complete(Self.overviewInstructions, input)
        try updateRecord(memoryCourseId) { $0.overview = overview; $0.overviewSignature = signature }
    }

    /// One digest for the whole file: in one call, or in parts at page boundaries and condensed.
    private func digest(itemId: Int64, title: String) async throws -> String {
        let pages = try await database.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT page, text FROM uni_page WHERE item_id = ? ORDER BY page, ordinal", arguments: [itemId])
                .map { (page: $0["page"] as Int, text: $0["text"] as String) }
        }
        let header = "File: \(title)\n\n"
        let parts = Self.split(pages, limit: Self.partSize - header.count)
        var digests: [String] = []
        for part in parts {
            if Task.isCancelled { throw CancellationError() }
            digests.append(try await complete(Self.digestInstructions, header + part))
        }
        if digests.count == 1 { return digests[0] }
        if Task.isCancelled { throw CancellationError() }
        return try await complete(Self.condenseInstructions, header + digests.enumerated().map { "Part \($0.offset + 1):\n\($0.element)" }.joined(separator: "\n\n"))
    }

    /// Page text with `[p. N]` markers, cut into parts of at most `limit` characters at page
    /// boundaries (a single page longer than that is cut inside).
    static func split(_ pages: [(page: Int, text: String)], limit: Int) -> [String] {
        var parts: [String] = []
        var current = ""
        for page in pages {
            let block = "[p. \(page.page)]\n\(page.text)\n\n"
            var pieces = [block]
            if block.count > limit {
                pieces = stride(from: 0, to: block.count, by: limit).map {
                    let start = block.index(block.startIndex, offsetBy: $0)
                    return String(block[start..<(block.index(start, offsetBy: limit, limitedBy: block.endIndex) ?? block.endIndex)])
                }
            }
            for piece in pieces {
                if !current.isEmpty, current.count + piece.count > limit {
                    parts.append(current)
                    current = ""
                }
                current += piece
            }
        }
        if !current.isEmpty || parts.isEmpty { parts.append(current) }
        return parts
    }

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static let digestInstructions = """
        You write a study digest of one university course file (lecture slides, script or exercise sheet) \
        for a student who will later use it to solve assignments. Page markers like [p. 3] show the page. \
        Start with the file's title and section. Then cover, in Markdown: the topics; definitions; \
        notation and symbols; formulas and theorems; and worked methods and examples, with page references. \
        If the file is an exercise or assignment sheet, list its tasks and its submission rules (format, \
        deadline, points, allowed tools). Be faithful to the file; never invent content. \
        Length: 300 to 1,500 words.
        """

    static let condenseInstructions = """
        You get digests of consecutive parts of one university course file. Merge them into one digest of \
        the whole file in Markdown: title and section first, then topics, definitions, notation and symbols, \
        formulas and theorems, worked methods (keep page references), and for exercise sheets their tasks and \
        submission rules. Remove repetition. Length: 300 to 1,500 words.
        """

    static let overviewInstructions = """
        You get digests of all files of one university course. Write a course overview in Markdown: what the \
        course covers, its topics in order, shared notation and symbols, the key formulas and methods, and \
        which file covers what (name the files). Keep submission rules of exercise sheets. \
        Length: 400 to 1,200 words.
        """
}
