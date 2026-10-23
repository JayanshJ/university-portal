import GRDB

extension UniDatabase {
    static let tableNames = [
        "uni_source", "uni_course", "uni_item", "uni_file", "uni_sync_run", "uni_state",
    ]

    /// Append new migrations at the end; never edit one that has shipped.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial") { db in
            try db.create(table: "uni_source") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull().unique()
                    .check(sql: "kind IN ('moodle', 'cms')")
                t.column("status", .text).notNull().defaults(to: "ok")
                    .check(sql: "status IN ('ok', 'needs_reconnect', 'degraded', 'error')")
                t.column("last_sync_at", .datetime)
                t.column("last_error", .text)
            }

            try db.create(table: "uni_course") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("source_id", .integer).notNull().indexed()
                    .references("uni_source", onDelete: .cascade)
                t.column("external_id", .text).notNull()  // Moodle course id or CMS slug
                t.column("short_name", .text).notNull()
                t.column("full_name", .text).notNull()
                t.column("url", .text)
                t.column("active", .boolean).notNull().defaults(to: true)
                t.column("offline", .boolean).notNull().defaults(to: false)
                t.column("ics_url", .text)
                t.column("hidden_categories", .jsonText).notNull().defaults(to: "[]")
                t.uniqueKey(["source_id", "external_id"])
            }

            try db.create(table: "uni_item") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("course_id", .integer).notNull().indexed()
                    .references("uni_course", onDelete: .cascade)
                t.column("kind", .text).notNull()
                    .check(sql: "kind IN ('deadline', 'announcement', 'event', 'material')")
                t.column("external_id", .text).notNull()
                t.column("title", .text).notNull()
                t.column("body_html", .text)
                t.column("starts_at", .datetime)
                t.column("due_at", .datetime)
                t.column("url", .text)
                t.column("category", .text)
                t.column("is_exam", .boolean).notNull().defaults(to: false)
                t.column("content_hash", .text).notNull()
                t.column("first_seen_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
                t.column("read_at", .datetime)
                t.column("done_at", .datetime)
                t.column("done_source", .text).check(sql: "done_source IN ('user', 'moodle')")
                t.column("missing_count", .integer).notNull().defaults(to: 0)
                t.column("deleted_at", .datetime)
                t.uniqueKey(["course_id", "kind", "external_id"])
            }
            try db.create(index: "uni_item_on_due_at", on: "uni_item", columns: ["due_at"])
            try db.create(index: "uni_item_on_first_seen_at", on: "uni_item", columns: ["first_seen_at"])

            try db.create(table: "uni_file") { t in
                t.primaryKey("item_id", .integer)
                    .references("uni_item", onDelete: .cascade)
                t.column("filename", .text).notNull()
                t.column("mimetype", .text)
                t.column("size_bytes", .integer)
                t.column("remote_url", .text).notNull()
                t.column("remote_modified_at", .datetime)
                t.column("sha256", .text)
                t.column("local_path", .text)  // empty until first open
                t.column("fetched_at", .datetime)
            }

            try db.create(table: "uni_sync_run") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("source_id", .integer).notNull().indexed()
                    .references("uni_source", onDelete: .cascade)
                t.column("job", .text).notNull()
                t.column("started_at", .datetime).notNull()
                t.column("finished_at", .datetime)
                t.column("ok", .boolean)
                t.column("counts", .jsonText)
                t.column("error", .text)
            }
            try db.create(
                index: "uni_sync_run_on_source_started", on: "uni_sync_run",
                columns: ["source_id", "started_at"])

            try db.create(table: "uni_state") { t in
                t.primaryKey("key", .text)
                t.column("value", .jsonText).notNull()
                t.column("updated_at", .datetime).notNull()
            }
        }

        // `active` is the effective value; `active_override` holds the user's choice (NULL = automatic).
        migrator.registerMigration("v2_course_active_override") { db in
            try db.alter(table: "uni_course") { t in
                t.add(column: "active_override", .boolean)
            }
        }

        // `auto_active` is what the sync decided (term in the name, else end date), so clearing an
        // override can restore it without waiting for the next sync.
        migrator.registerMigration("v3_course_auto_active") { db in
            try db.alter(table: "uni_course") { t in
                t.add(column: "auto_active", .boolean).notNull().defaults(to: true)
            }
            try db.execute(sql: "UPDATE uni_course SET auto_active = active WHERE active_override IS NULL")
        }

        // Calendar events need an end, a place, and whether they are all-day.
        migrator.registerMigration("v4_item_event_fields") { db in
            try db.alter(table: "uni_item") { t in
                t.add(column: "ends_at", .datetime)
                t.add(column: "location", .text)
                t.add(column: "all_day", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "uni_item_on_starts_at", on: "uni_item", columns: ["starts_at"])
        }

        // "Due date changed" is shown on a deadline for a while after Moodle moves it. Everything
        // stored so far came from first imports, which should not count as unread news.
        migrator.registerMigration("v5_due_changed_and_read_baseline") { db in
            try db.alter(table: "uni_item") { t in
                t.add(column: "due_changed_at", .datetime)
            }
            try db.execute(sql: """
                UPDATE uni_item SET read_at = first_seen_at
                WHERE read_at IS NULL AND kind IN ('announcement', 'material', 'event')
                """)
        }

        // Ask your materials: PDF text per page, chunked, with a full-text index over the chunks.
        migrator.registerMigration("v6_material_pages") { db in
            try db.create(table: "uni_page") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("item_id", .integer).notNull().indexed()
                    .references("uni_item", onDelete: .cascade)
                t.column("page", .integer).notNull()  // 1-based PDF page
                t.column("ordinal", .integer).notNull()  // chunk order within the document
                t.column("text", .text).notNull()
            }
            try db.create(virtualTable: "uni_page_fts", using: FTS5()) { t in
                t.synchronize(withTable: "uni_page")
                t.tokenizer = .porter(wrapping: .unicode61())
                t.column("text")
            }
            try db.create(table: "uni_index") { t in
                t.primaryKey("item_id", .integer).references("uni_item", onDelete: .cascade)
                t.column("sha256", .text)
                t.column("pages", .integer).notNull()
                t.column("chunks", .integer).notNull()
                t.column("indexed_at", .datetime).notNull()
                t.column("error", .text)
            }
        }

        return migrator
    }
}
