import Foundation
import GRDB

/// Opens a material's file: from the cache if present, otherwise downloaded from its source first.
public struct MaterialFiles: Sendable {
    let database: UniDatabase
    let cache: FileCache
    let secrets: any SecretStore
    let transport: any HTTPTransport

    public init(database: UniDatabase, cache: FileCache, secrets: any SecretStore, transport: any HTTPTransport) {
        self.database = database
        self.cache = cache
        self.secrets = secrets
        self.transport = transport
    }

    /// Returns the local file and marks the material as read.
    public func open(itemId: Int64) async throws -> URL {
        let found = try await database.writer.read { db -> (UniFile, SourceKind)? in
            guard let file = try UniFile.fetchOne(db, key: itemId) else { return nil }
            let kind = try String.fetchOne(db, sql: """
                SELECT s.kind FROM uni_item i
                JOIN uni_course c ON c.id = i.course_id
                JOIN uni_source s ON s.id = c.source_id
                WHERE i.id = ?
                """, arguments: [itemId])
            return kind.flatMap(SourceKind.init(rawValue:)).map { (file, $0) }
        }
        guard let (file, kind) = found else { throw FileCacheError.noFile }

        let url: URL
        if let sha256 = file.sha256, let cached = await cache.cachedURL(sha256: sha256, filename: file.filename) {
            url = cached
        } else {
            let data = try await download(file, from: kind)
            let stored = try await cache.store(data, filename: file.filename)
            url = stored.url
            try await database.writer.write { db in
                var updated = file
                updated.sha256 = stored.sha256
                updated.localPath = stored.url.path
                updated.fetchedAt = .now
                try updated.update(db)
            }
        }

        try await database.writer.write { db in
            try db.execute(sql: "UPDATE uni_item SET read_at = ? WHERE id = ? AND read_at IS NULL",
                           arguments: [Date.now, itemId])
        }
        return url
    }

    private func download(_ file: UniFile, from kind: SourceKind) async throws -> Data {
        switch kind {
        case .moodle:
            guard let token = try secrets.readString(.moodleToken) else { throw FileCacheError.notConnected }
            return try await MoodleClient(token: token, transport: transport).download(file.remoteUrl).data
        case .cms:
            throw FileCacheError.downloadNotImplemented
        }
    }
}
