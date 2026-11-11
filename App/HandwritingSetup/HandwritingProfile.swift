import AppKit
import Foundation

/// The student's own handwriting, for Solve's handwritten PDFs: glyph images in Math Writer's
/// format (metadata.json + PNGs), kept only in this app's container on this Mac. Nothing ships
/// with the app; each student makes theirs from the template, or imports a Math Writer library.
@MainActor @Observable
final class HandwritingProfile {
    static let shared = HandwritingProfile()

    struct Summary: Equatable {
        var characters: Int
        var variants: Int
        var missing: [Character]
    }

    private(set) var summary: Summary?
    var isSetUp: Bool { summary != nil }

    nonisolated static var folder: URL {
        URL.applicationSupportDirectory.appending(path: "Handwriting/glyphs", directoryHint: .isDirectory)
    }
    nonisolated static var metadataURL: URL { folder.appending(path: "metadata.json") }

    private init() { refresh() }

    func refresh() {
        guard let metadata = Self.readMetadata(), !metadata.isEmpty else {
            summary = nil
            return
        }
        let have = Set(metadata.keys.compactMap(\.first))
        let missing = HandwritingTemplate.characters.map(\.0).filter { !have.contains($0) }
        summary = Summary(characters: metadata.count, variants: metadata.values.map(\.count).reduce(0, +), missing: missing)
    }

    // MARK: - Metadata

    struct Variant: Codable, Sendable {
        var file: String
        var top_off: Int
        var baseline_y: Int
        var w: Int
        var h: Int
    }

    nonisolated static func readMetadata(at url: URL = metadataURL) -> [String: [Variant]]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([String: [Variant]].self, from: data)
    }

    /// The first variant of each character, for previews.
    func samples() -> [(Character, NSImage)] {
        guard let metadata = Self.readMetadata() else { return [] }
        return HandwritingTemplate.characters.compactMap { character, _ in
            guard let variant = metadata[String(character)]?.first,
                  let image = NSImage(contentsOf: Self.folder.appending(path: (variant.file as NSString).lastPathComponent)) else { return nil }
            return (character, image)
        }
    }

    // MARK: - Saving

    /// Replaces the handwriting with the glyphs read from template pages.
    func save(_ pages: [TemplateReader.Page]) throws {
        try Self.write(pages, to: Self.folder)
        refresh()
    }

    /// Writes template glyphs as a Math Writer library into `destination` (replacing it).
    nonisolated static func write(_ pages: [TemplateReader.Page], to destination: URL) throws {
        let staging = try freshStaging(next: destination)
        var metadata: [String: [Variant]] = [:]
        var counter: [Character: Int] = [:]
        for glyph in pages.flatMap(\.glyphs) {
            let n = counter[glyph.character, default: 0]
            counter[glyph.character] = n + 1
            let name = String(format: "U%04X_s%d.png", glyph.character.unicodeScalars.first!.value, n)
            try glyph.png.write(to: staging.appending(path: name))
            metadata[String(glyph.character), default: []].append(
                Variant(file: name, top_off: 0, baseline_y: glyph.baseline + 48, w: glyph.width, h: glyph.height))
        }
        try JSONEncoder().encode(metadata).write(to: staging.appending(path: "metadata.json"))
        try replace(destination, with: staging)
    }

    /// Copies a Math Writer glyph library (its `glyphs` folder, or the Math Writer folder itself).
    func importMathWriter(from chosen: URL) throws {
        let scoped = chosen.startAccessingSecurityScopedResource()
        defer { if scoped { chosen.stopAccessingSecurityScopedResource() } }
        var source = chosen
        if Self.readMetadata(at: source.appending(path: "metadata.json")) == nil { source = chosen.appending(path: "glyphs") }
        guard var metadata = Self.readMetadata(at: source.appending(path: "metadata.json")) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "That folder has no Math Writer glyphs (glyphs/metadata.json)."])
        }
        let staging = try Self.freshStaging(next: Self.folder)
        for (key, variants) in metadata {
            metadata[key] = try variants.map { variant in
                let name = (variant.file as NSString).lastPathComponent
                try FileManager.default.copyItem(at: source.appending(path: name), to: staging.appending(path: name))
                var copy = variant
                copy.file = name
                return copy
            }
        }
        try JSONEncoder().encode(metadata).write(to: staging.appending(path: "metadata.json"))
        try Self.replace(Self.folder, with: staging)
        refresh()
    }

    func remove() {
        try? FileManager.default.removeItem(at: Self.folder)
        refresh()
    }

    nonisolated private static func freshStaging(next destination: URL) throws -> URL {
        let staging = destination.deletingLastPathComponent().appending(path: "staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        return staging
    }

    nonisolated private static func replace(_ destination: URL, with staging: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: staging, to: destination)
    }
}
