import Foundation
import GRDB

public enum SourceKind: String, Codable, Sendable {
    case moodle, cms
}

public enum SourceStatus: String, Codable, Sendable {
    case ok
    case needsReconnect = "needs_reconnect"
    case degraded
    case error
}

public enum ItemKind: String, Codable, Sendable {
    case deadline, announcement, event, material
}

public enum DoneSource: String, Codable, Sendable {
    case user, moodle
}

// Records map camelCase properties to the snake_case columns of Schema.swift.

public struct UniSource: Codable, Sendable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "uni_source"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public var id: Int64?
    public var kind: SourceKind
    public var status: SourceStatus
    public var lastSyncAt: Date?
    public var lastError: String?

    public init(id: Int64? = nil, kind: SourceKind, status: SourceStatus = .ok,
                lastSyncAt: Date? = nil, lastError: String? = nil) {
        self.id = id
        self.kind = kind
        self.status = status
        self.lastSyncAt = lastSyncAt
        self.lastError = lastError
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct UniCourse: Codable, Sendable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "uni_course"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public var id: Int64?
    public var sourceId: Int64
    public var externalId: String
    public var shortName: String
    public var fullName: String
    public var url: String?
    public var active: Bool
    public var offline: Bool
    public var icsUrl: String?
    public var hiddenCategories: [String]
    public var activeOverride: Bool?
    public var autoActive: Bool

    public init(id: Int64? = nil, sourceId: Int64, externalId: String, shortName: String,
                fullName: String, url: String? = nil, active: Bool = true, offline: Bool = false,
                icsUrl: String? = nil, hiddenCategories: [String] = [], activeOverride: Bool? = nil,
                autoActive: Bool = true) {
        self.id = id
        self.sourceId = sourceId
        self.externalId = externalId
        self.shortName = shortName
        self.fullName = fullName
        self.url = url
        self.active = active
        self.offline = offline
        self.icsUrl = icsUrl
        self.hiddenCategories = hiddenCategories
        self.activeOverride = activeOverride
        self.autoActive = autoActive
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct UniItem: Codable, Sendable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "uni_item"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public var id: Int64?
    public var courseId: Int64
    public var kind: ItemKind
    public var externalId: String
    public var title: String
    public var bodyHtml: String?
    public var startsAt: Date?
    public var dueAt: Date?
    public var endsAt: Date?
    public var location: String?
    public var allDay: Bool
    public var url: String?
    public var category: String?
    public var isExam: Bool
    public var contentHash: String
    public var firstSeenAt: Date
    public var updatedAt: Date
    public var readAt: Date?
    public var doneAt: Date?
    public var doneSource: DoneSource?
    public var missingCount: Int
    public var deletedAt: Date?

    public init(id: Int64? = nil, courseId: Int64, kind: ItemKind, externalId: String,
                title: String, bodyHtml: String? = nil, startsAt: Date? = nil, dueAt: Date? = nil,
                endsAt: Date? = nil, location: String? = nil, allDay: Bool = false,
                url: String? = nil, category: String? = nil, isExam: Bool = false,
                contentHash: String, firstSeenAt: Date = .now, updatedAt: Date = .now,
                readAt: Date? = nil, doneAt: Date? = nil, doneSource: DoneSource? = nil,
                missingCount: Int = 0, deletedAt: Date? = nil) {
        self.id = id
        self.courseId = courseId
        self.kind = kind
        self.externalId = externalId
        self.title = title
        self.bodyHtml = bodyHtml
        self.startsAt = startsAt
        self.dueAt = dueAt
        self.endsAt = endsAt
        self.location = location
        self.allDay = allDay
        self.url = url
        self.category = category
        self.isExam = isExam
        self.contentHash = contentHash
        self.firstSeenAt = firstSeenAt
        self.updatedAt = updatedAt
        self.readAt = readAt
        self.doneAt = doneAt
        self.doneSource = doneSource
        self.missingCount = missingCount
        self.deletedAt = deletedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct UniFile: Codable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "uni_file"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public var itemId: Int64
    public var filename: String
    public var mimetype: String?
    public var sizeBytes: Int64?
    public var remoteUrl: String
    public var remoteModifiedAt: Date?
    public var sha256: String?
    public var localPath: String?
    public var fetchedAt: Date?

    public init(itemId: Int64, filename: String, mimetype: String? = nil, sizeBytes: Int64? = nil,
                remoteUrl: String, remoteModifiedAt: Date? = nil, sha256: String? = nil,
                localPath: String? = nil, fetchedAt: Date? = nil) {
        self.itemId = itemId
        self.filename = filename
        self.mimetype = mimetype
        self.sizeBytes = sizeBytes
        self.remoteUrl = remoteUrl
        self.remoteModifiedAt = remoteModifiedAt
        self.sha256 = sha256
        self.localPath = localPath
        self.fetchedAt = fetchedAt
    }
}

public struct UniSyncRun: Codable, Sendable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "uni_sync_run"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public var id: Int64?
    public var sourceId: Int64
    public var job: String
    public var startedAt: Date
    public var finishedAt: Date?
    public var ok: Bool?
    public var counts: [String: Int]?
    public var error: String?

    public init(id: Int64? = nil, sourceId: Int64, job: String, startedAt: Date = .now,
                finishedAt: Date? = nil, ok: Bool? = nil, counts: [String: Int]? = nil,
                error: String? = nil) {
        self.id = id
        self.sourceId = sourceId
        self.job = job
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.ok = ok
        self.counts = counts
        self.error = error
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
