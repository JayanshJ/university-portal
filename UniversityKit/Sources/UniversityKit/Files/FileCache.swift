import CryptoKit
import Foundation

public enum FileCacheError: Error, Equatable {
    /// CMS downloads arrive with the CMS login in Phase 4.
    case downloadNotImplemented
    case notConnected
    case noFile
}

/// File bytes on disk, named `<sha256>.<extension>`, fetched on first open.
public actor FileCache {
    public let directory: URL

    public init(directory: URL = AppPaths.filesDirectory) {
        self.directory = directory
    }

    public func cachedURL(sha256: String, filename: String) -> URL? {
        let url = location(sha256: sha256, filename: filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Saves `data` and returns its hash and location. Storing the same bytes twice is a no-op.
    @discardableResult
    public func store(_ data: Data, filename: String) throws -> (sha256: String, url: URL) {
        let sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let url = location(sha256: sha256, filename: filename)
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        return (sha256, url)
    }

    public func sizeInBytes() throws -> Int64 {
        guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey])
        return try files.reduce(0) { total, url in
            total + Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
    }

    /// Callers must also clear `uni_file.local_path` for the removed files.
    public func clear() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    /// The extension keeps the file openable by other apps (Preview, Quick Look).
    private func location(sha256: String, filename: String) -> URL {
        let ext = (filename as NSString).pathExtension.lowercased()
        return directory.appending(path: ext.isEmpty ? sha256 : "\(sha256).\(ext)")
    }
}
