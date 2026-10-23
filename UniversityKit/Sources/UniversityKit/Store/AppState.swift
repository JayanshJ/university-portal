import Foundation
import GRDB

/// Keys of the `uni_state` table.
public enum StateKey: String, Sendable {
    case lastVisitAt = "last_visit_at"
    case pdfDarkPages = "pdf_dark_pages"
    case moodlePassport = "moodle_passport"
    case moodleDiagnostics = "moodle_diagnostics"
    case cmsLogin = "cms_login"
    /// Per course: the file count and the content links the materials parser did not take.
    case cmsMaterialsDiagnostics = "cms_materials_diagnostics"
    /// The ChatGPT model chosen for Ask (a slug).
    case chatgptModel = "chatgpt_model"
    /// Whether the one-time "You're using your ChatGPT plan" notice was shown.
    case chatgptWelcomeShown = "chatgpt_welcome_shown"
}

/// What the Moodle side has learned about itself. No secrets: safe to show in Settings and to inspect.
public struct MoodleDiagnostics: Codable, Sendable, Equatable {
    public enum ConnectMethod: String, Codable, Sendable { case browser, sheet, paste }
    public enum DeadlinesMode: String, Codable, Sendable {
        /// `core_calendar_get_action_events_by_timesort` works with the token.
        case actionEvents = "action_events"
        /// It was refused; `mod_assign_get_assignments` is used instead.
        case assignFallback = "assign_fallback"
    }

    public var connectedAt: Date?
    public var connectedVia: ConnectMethod?
    /// Why the last sign-in sheet attempt did not return a `moodlemobile://` callback; nil after a success.
    public var sheetFailure: String?
    /// nil = no passport to compare against (expired, or a paste without one).
    public var siteHashMatched: Bool?
    public var release: String?
    public var deadlinesMode: DeadlinesMode?
    public var deadlinesCheckedAt: Date?
    public var deadlinesFallbackReason: String?
    /// Set when the token dies, to learn its real lifetime.
    public var tokenAgeAtFailureHours: Double?

    public init() {}
}

/// A reconnect in progress: the passport sent to `launch.php` and when it stops being accepted.
public struct MoodlePassport: Codable, Sendable, Equatable {
    public var value: String
    public var expiresAt: Date

    public init(value: String, expiresAt: Date) {
        self.value = value
        self.expiresAt = expiresAt
    }
}

struct UniStateRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "uni_state"
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    var key: String
    var value: String
    var updatedAt: Date
}

extension UniDatabase {
    public func state<Value: Decodable>(_ key: StateKey, as type: Value.Type = Value.self) throws -> Value? {
        let row = try writer.read { db in try UniStateRow.fetchOne(db, key: key.rawValue) }
        guard let row else { return nil }
        return try Self.jsonDecoder.decode(Value.self, from: Data(row.value.utf8))
    }

    public func setState<Value: Encodable>(_ key: StateKey, to value: Value) throws {
        let json = String(decoding: try Self.jsonEncoder.encode(value), as: UTF8.self)
        try writer.write { db in
            try UniStateRow(key: key.rawValue, value: json, updatedAt: .now).upsert(db)
        }
    }

    /// Read-modify-write of one state value in a single transaction.
    public func updateState<Value: Codable>(
        _ key: StateKey, default defaultValue: Value, _ change: (inout Value) -> Void
    ) throws {
        try writer.write { db in
            var value = try Self.state(db, key, as: Value.self) ?? defaultValue
            change(&value)
            let json = String(decoding: try Self.jsonEncoder.encode(value), as: UTF8.self)
            try UniStateRow(key: key.rawValue, value: json, updatedAt: .now).upsert(db)
        }
    }

    static func state<Value: Decodable>(_ db: Database, _ key: StateKey, as type: Value.Type) throws -> Value? {
        guard let row = try UniStateRow.fetchOne(db, key: key.rawValue) else { return nil }
        return try jsonDecoder.decode(Value.self, from: Data(row.value.utf8))
    }

    public func removeState(_ key: StateKey) throws {
        _ = try writer.write { db in try UniStateRow.deleteOne(db, key: key.rawValue) }
    }

    private static var jsonEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var jsonDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
