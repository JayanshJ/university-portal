import Foundation
import GRDB

/// What Solve remembers about one course file: a digest of its content, keyed by the file's hash
/// and the prompt version so it is only regenerated when either changes.
public struct MemoryFile: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "uni_memory_file"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public var itemId: Int64
    public var courseId: Int64
    public var sha256: String?
    public var promptVersion: Int
    public var model: String?
    public var digest: String
    public var edited: Bool
    public var updatedAt: Date
    public var error: String?

    public init(itemId: Int64, courseId: Int64, sha256: String? = nil, promptVersion: Int, model: String? = nil,
                digest: String = "", edited: Bool = false, updatedAt: Date = .now, error: String? = nil) {
        self.itemId = itemId
        self.courseId = courseId
        self.sha256 = sha256
        self.promptVersion = promptVersion
        self.model = model
        self.digest = digest
        self.edited = edited
        self.updatedAt = updatedAt
        self.error = error
    }
}

/// The per-course overview and the user's own notes.
public struct CourseMemoryRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "uni_memory"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public var courseId: Int64
    public var overview: String
    public var overviewEdited: Bool
    public var notes: String
    public var overviewSignature: String?
    public var updatedAt: Date

    public init(courseId: Int64, overview: String = "", overviewEdited: Bool = false, notes: String = "",
                overviewSignature: String? = nil, updatedAt: Date = .now) {
        self.courseId = courseId
        self.overview = overview
        self.overviewEdited = overviewEdited
        self.notes = notes
        self.overviewSignature = overviewSignature
        self.updatedAt = updatedAt
    }
}
