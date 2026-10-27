import CryptoKit
import Foundation
import GRDB

/// A course as an adapter sees it.
public struct CourseInput: Sendable, Equatable {
    public var externalId: String
    public var shortName: String
    public var fullName: String
    public var url: String?
    /// The automatic value; a user override in `uni_course.active_override` wins.
    public var active: Bool
    public var icsUrl: String?

    public init(externalId: String, shortName: String, fullName: String, url: String? = nil,
                active: Bool = true, icsUrl: String? = nil) {
        self.externalId = externalId
        self.shortName = shortName
        self.fullName = fullName
        self.url = url
        self.active = active
        self.icsUrl = icsUrl
    }
}

/// A file attached to a material item.
public struct FileInput: Sendable, Equatable {
    public var filename: String
    public var mimetype: String?
    public var sizeBytes: Int64?
    public var remoteUrl: String
    public var remoteModifiedAt: Date?

    public init(filename: String, mimetype: String? = nil, sizeBytes: Int64? = nil,
                remoteUrl: String, remoteModifiedAt: Date? = nil) {
        self.filename = filename
        self.mimetype = mimetype
        self.sizeBytes = sizeBytes
        self.remoteUrl = remoteUrl
        self.remoteModifiedAt = remoteModifiedAt
    }
}

/// An item as an adapter sees it, before it is matched against the store.
public struct ItemInput: Sendable, Equatable {
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
    public var file: FileInput?
    public var position: Int?
    public var details: [String: String]?

    public init(courseId: Int64, kind: ItemKind, externalId: String, title: String,
                bodyHtml: String? = nil, startsAt: Date? = nil, dueAt: Date? = nil,
                endsAt: Date? = nil, location: String? = nil, allDay: Bool = false, url: String? = nil,
                category: String? = nil, isExam: Bool = false, file: FileInput? = nil,
                position: Int? = nil, details: [String: String]? = nil) {
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
        self.file = file
        self.position = position
        self.details = details
    }

    /// SHA-256 of the fields shown in the UI. A different hash means "updated".
    var contentHash: String {
        let fields: [String] = [
            title, bodyHtml ?? "", category ?? "", isExam ? "1" : "0",
            startsAt.map { String(Int($0.timeIntervalSince1970)) } ?? "",
            dueAt.map { String(Int($0.timeIntervalSince1970)) } ?? "",
            file.map { "\($0.sizeBytes ?? -1)" } ?? "",
            file?.remoteModifiedAt.map { String(Int($0.timeIntervalSince1970)) } ?? "",
        ] + (endsAt == nil && location == nil && !allDay ? [] : [
            endsAt.map { String(Int($0.timeIntervalSince1970)) } ?? "", location ?? "", allDay ? "1" : "0",
        ]) + (details ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        let digest = SHA256.hash(data: Data(fields.joined(separator: "\u{1F}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public enum UniEvent: Sendable, Equatable {
    case itemCreated(itemId: Int64)
    case itemUpdated(itemId: Int64, dueDateChanged: Bool)
}

public struct SyncCounts: Sendable, Equatable {
    public var new = 0
    public var updated = 0
    public var unchanged = 0
    public var missing = 0
    public var deleted = 0
    public var doneByMoodle = 0

    public init() {}

    static func + (lhs: SyncCounts, rhs: SyncCounts) -> SyncCounts {
        var sum = lhs
        sum.new += rhs.new
        sum.updated += rhs.updated
        sum.unchanged += rhs.unchanged
        sum.missing += rhs.missing
        sum.deleted += rhs.deleted
        sum.doneByMoodle += rhs.doneByMoodle
        return sum
    }

    var dictionary: [String: Int] {
        ["new": new, "updated": updated, "unchanged": unchanged, "missing": missing,
         "deleted": deleted, "done_by_moodle": doneByMoodle]
    }
}

/// What one run did. `suspectCourseIds` are courses whose results looked like a parser failure.
public struct SyncOutcome: Sendable, Equatable {
    public var counts = SyncCounts()
    public var events: [UniEvent] = []
    public var suspectCourseIds: Set<Int64> = []

    public init() {}

    static func + (lhs: SyncOutcome, rhs: SyncOutcome) -> SyncOutcome {
        var sum = lhs
        sum.counts = lhs.counts + rhs.counts
        sum.events += rhs.events
        sum.suspectCourseIds.formUnion(rhs.suspectCourseIds)
        return sum
    }
}

/// Writes adapter results into the store, following the rules in the plan's "Sync and change detection".
enum Upserter {
    /// Inserts or updates courses; returns their row ids by external id.
    static func upsertCourses(_ db: Database, sourceId: Int64, _ inputs: [CourseInput]) throws -> [String: Int64] {
        var ids: [String: Int64] = [:]
        for input in inputs {
            let existing = try UniCourse
                .filter(Column("source_id") == sourceId && Column("external_id") == input.externalId)
                .fetchOne(db)
            var course = existing ?? UniCourse(sourceId: sourceId, externalId: input.externalId,
                                               shortName: input.shortName, fullName: input.fullName)
            course.shortName = input.shortName
            course.fullName = input.fullName
            course.url = input.url ?? course.url
            course.icsUrl = input.icsUrl ?? course.icsUrl
            course.autoActive = input.active
            course.active = course.activeOverride ?? input.active
            try course.save(db)
            ids[input.externalId] = course.id
        }
        return ids
    }

    /// Applies one run's items for `kind` across `courseIds` (the scope this run covered).
    /// Items in scope that the run did not return count as missing.
    static func apply(
        _ db: Database, kind: ItemKind, courseIds: Set<Int64>, items: [ItemInput], now: Date
    ) throws -> SyncOutcome {
        var outcome = SyncOutcome()
        let existing = try UniItem
            .filter(Column("kind") == kind.rawValue && courseIds.contains(Column("course_id")))
            .fetchAll(db)
        var byKey = Dictionary(uniqueKeysWithValues: existing.map { ("\($0.courseId)/\($0.externalId)", $0) })
        let coursesWithItems = Set(existing.map(\.courseId))
        var seen = Set<String>()

        for input in items where courseIds.contains(input.courseId) {
            let key = "\(input.courseId)/\(input.externalId)"
            guard seen.insert(key).inserted else { continue }
            let hash = input.contentHash

            if var item = byKey[key] {
                let changed = item.contentHash != hash
                let dueChanged = item.dueAt.map(Int.init) != input.dueAt.map(Int.init)
                let wasGone = item.deletedAt != nil
                // News again: more replies in a thread, or a grade given or changed.
                let renewed = Int(input.details?["replies"] ?? "") ?? 0 > Int(item.details?["replies"] ?? "") ?? 0
                    || (kind == .grade && input.category != nil && input.category != item.category)
                fill(&item, from: input, hash: hash)
                item.missingCount = 0
                item.deletedAt = nil
                if item.doneSource == .moodle {
                    // Back in Moodle's open list, e.g. a submission reverted to draft.
                    item.doneAt = nil
                    item.doneSource = nil
                }
                if changed || wasGone {
                    item.updatedAt = now
                    if renewed { item.readAt = nil }
                    if kind == .deadline, dueChanged { item.dueChangedAt = now }
                    outcome.counts.updated += 1
                    outcome.events.append(.itemUpdated(itemId: item.id!, dueDateChanged: dueChanged))
                } else {
                    outcome.counts.unchanged += 1
                }
                try item.update(db)
                byKey[key] = item
                try upsertFile(db, itemId: item.id!, input.file)
            } else {
                var item = UniItem(courseId: input.courseId, kind: kind, externalId: input.externalId,
                                   title: input.title, contentHash: hash, firstSeenAt: now, updatedAt: now)
                fill(&item, from: input, hash: hash)
                // A course's first import is history, not news: only later additions start unread.
                if kind != .deadline, !coursesWithItems.contains(input.courseId) { item.readAt = now }
                try item.insert(db)
                outcome.counts.new += 1
                outcome.events.append(.itemCreated(itemId: item.id!))
                try upsertFile(db, itemId: item.id!, input.file)
            }
        }

        // Zero-results guard: a course that had items and suddenly has none is a suspected parser
        // failure, so its rows are kept. Deadlines are exempt: an empty list is normal there.
        let returnedCourses = Set(items.map(\.courseId))
        let liveByCourse = Dictionary(grouping: existing.filter { $0.deletedAt == nil }, by: \.courseId)
        let suspect = kind == .deadline ? [] : Set(liveByCourse.keys).subtracting(returnedCourses)
        outcome.suspectCourseIds = suspect

        for var item in existing where item.deletedAt == nil {
            let key = "\(item.courseId)/\(item.externalId)"
            guard !seen.contains(key), !suspect.contains(item.courseId) else { continue }
            if item.doneSource == .moodle { continue }  // already resolved as submitted

            item.missingCount += 1
            outcome.counts.missing += 1
            if item.missingCount >= 2 {
                if kind == .deadline, item.doneAt == nil, let due = item.dueAt, due > now {
                    // Moodle drops submitted assignments from the open list before they are due.
                    item.doneAt = now
                    item.doneSource = .moodle
                    outcome.counts.doneByMoodle += 1
                } else {
                    item.deletedAt = now
                    outcome.counts.deleted += 1
                }
            }
            try item.update(db)
        }
        return outcome
    }

    private static func fill(_ item: inout UniItem, from input: ItemInput, hash: String) {
        item.title = input.title
        item.bodyHtml = input.bodyHtml
        item.startsAt = input.startsAt
        item.dueAt = input.dueAt
        item.endsAt = input.endsAt
        item.location = input.location
        item.allDay = input.allDay
        item.url = input.url
        item.category = input.category
        item.isExam = input.isExam
        item.position = input.position
        item.details = input.details
        item.contentHash = hash
    }

    private static func upsertFile(_ db: Database, itemId: Int64, _ input: FileInput?) throws {
        guard let input else { return }
        let existing = try UniFile.fetchOne(db, key: itemId)
        var file = UniFile(itemId: itemId, filename: input.filename, mimetype: input.mimetype,
                           sizeBytes: input.sizeBytes, remoteUrl: input.remoteUrl,
                           remoteModifiedAt: input.remoteModifiedAt)
        // Keep the cached copy unless the remote file changed.
        if let existing, existing.sizeBytes == input.sizeBytes,
           existing.remoteModifiedAt.map(Int.init) == input.remoteModifiedAt.map(Int.init) {
            file.sha256 = existing.sha256
            file.localPath = existing.localPath
            file.fetchedAt = existing.fetchedAt
        }
        try file.save(db)
    }
}

private extension Int {
    init(_ date: Date) { self = Int(date.timeIntervalSince1970) }
}
