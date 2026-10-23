import Foundation
import GRDB

/// The app's SQLite store. Opening it applies any pending migrations.
public final class UniDatabase: Sendable {
    public let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// Opens (or creates) the database file, creating its folder if needed.
    public static func onDisk(at url: URL = AppPaths.databaseURL) throws -> UniDatabase {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try UniDatabase(DatabasePool(path: url.path))
    }

    /// A throwaway database for tests and previews.
    public static func inMemory() throws -> UniDatabase {
        try UniDatabase(DatabaseQueue())
    }
}

public enum AppPaths {
    public static var supportDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "UniversityPortal", directoryHint: .isDirectory)
    }

    public static var databaseURL: URL {
        supportDirectory.appending(path: "uni.sqlite")
    }

    public static var filesDirectory: URL {
        supportDirectory.appending(path: "Files", directoryHint: .isDirectory)
    }
}
