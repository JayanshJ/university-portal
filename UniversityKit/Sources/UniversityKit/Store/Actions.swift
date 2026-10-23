import Foundation
import GRDB

extension UniDatabase {
    /// Marks a deadline done by the user, or undoes it.
    public func setDone(itemId: Int64, done: Bool) throws {
        try writer.write { db in
            guard var item = try UniItem.fetchOne(db, key: itemId) else { return }
            item.doneAt = done ? .now : nil
            item.doneSource = done ? .user : nil
            try item.update(db)
        }
    }

    public func setRead(itemId: Int64, read: Bool = true) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE uni_item SET read_at = ? WHERE id = ?", arguments: [read ? Date.now : nil, itemId])
        }
    }

    public func markAllRead(_ kind: ItemKind) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE uni_item SET read_at = ? WHERE kind = ? AND read_at IS NULL",
                           arguments: [Date.now, kind.rawValue])
        }
    }

    /// Leaving Today: what was new is no longer new since the last visit.
    public func markTodayVisited(at date: Date = .now) throws {
        try setState(.lastVisitAt, to: date)
    }

    /// Calendar events (active courses, hidden categories left out) and deadlines in `[from, to)`.
    public func schedule(from: Date, to: Date) throws -> [PortalOverview.ItemRow] {
        try writer.read { db in
            let courses = try UniCourse.filter(Column("active") == true).fetchAll(db)
            let sources = Dictionary(uniqueKeysWithValues: try UniSource.fetchAll(db).compactMap { s in s.id.map { ($0, s.kind) } })
            let byId = Dictionary(uniqueKeysWithValues: courses.compactMap { c in c.id.map { ($0, c) } })
            let items = try UniItem
                .filter(byId.keys.contains(Column("course_id")) && Column("deleted_at") == nil)
                .filter((Column("kind") == ItemKind.event.rawValue && Column("starts_at") >= from && Column("starts_at") < to)
                        || (Column("kind") == ItemKind.deadline.rawValue && Column("due_at") >= from && Column("due_at") < to))
                .fetchAll(db)
            return items.compactMap { item -> PortalOverview.ItemRow? in
                guard let course = byId[item.courseId] else { return nil }
                if item.kind == .event, let category = item.category, course.hiddenCategories.contains(category) { return nil }
                return PortalOverview.ItemRow(item, course: course, source: sources[course.sourceId] ?? .moodle,
                                              hasFile: false, isCached: false)
            }
            .sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
        }
    }
}
