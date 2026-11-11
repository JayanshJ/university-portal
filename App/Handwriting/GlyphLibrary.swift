import CoreGraphics
import Foundation
import ImageIO

/// A handwriting: glyph variants per character, in Math Writer's format.
struct GlyphLibrary: Sendable {
    /// One handwritten sample of a character, already recoloured to solid ink
    /// (as in Math Writer's `load_glyphs` + `recolor_to_blue`).
    struct Variant: Sendable {
        /// Ink coverage.
        var bitmap: AlphaBitmap
        /// Size from the metadata (the size the renderer scales from).
        var w: Int
        var h: Int
        /// Baseline in pixels from the glyph image's top (`baseline_y - 48`).
        var baselineY: Int
    }

    enum LoadError: LocalizedError {
        case unreadableMetadata(URL, underlying: Error)
        case unreadableImage(URL)

        var errorDescription: String? {
            switch self {
            case .unreadableMetadata(let url, let error):
                "Couldn’t read the handwriting metadata at \(url.path): \(error.localizedDescription)"
            case .unreadableImage(let url):
                "Couldn’t read the glyph image \(url.lastPathComponent)."
            }
        }
    }

    private(set) var variants: [Character: [Variant]]

    var characters: Set<Character> { Set(variants.keys) }

    init(variants: [Character: [Variant]]) {
        self.variants = variants
    }

    private struct MetadataEntry: Decodable {
        var file: String
        var baseline_y: Int
        var w: Int
        var h: Int
    }

    /// Loads `metadata.json` from `folder`; each variant's PNG is resolved by
    /// the last path component of its `file` inside `folder`.
    static func load(from folder: URL) throws -> GlyphLibrary {
        let metaURL = folder.appendingPathComponent("metadata.json")
        let meta: [String: [MetadataEntry]]
        do {
            meta = try JSONDecoder().decode([String: [MetadataEntry]].self, from: Data(contentsOf: metaURL))
        } catch {
            throw LoadError.unreadableMetadata(metaURL, underlying: error)
        }
        var variants: [Character: [Variant]] = [:]
        for (key, entries) in meta {
            guard key.count == 1, let ch = key.first else { continue }
            var list: [Variant] = []
            for entry in entries {
                let name = (entry.file as NSString).lastPathComponent
                let url = folder.appendingPathComponent(name)
                guard let alpha = loadAlpha(url) else { throw LoadError.unreadableImage(url) }
                list.append(Variant(bitmap: recolor(alpha), w: entry.w, h: entry.h,
                                    baselineY: entry.baseline_y - 48))
            }
            if !list.isEmpty { variants[ch] = list }
        }
        return GlyphLibrary(variants: variants)
    }

    /// The PNG's alpha channel.
    private static func loadAlpha(_ url: URL) -> AlphaBitmap? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = image.width, h = image.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let ok = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        var out = AlphaBitmap(width: w, height: h)
        for i in 0..<(w * h) { out.data[i] = rgba[i * 4 + 3] }
        return out
    }

    /// `recolor_to_blue`: solid ink where alpha > 30, faint pixels ×4, then a
    /// gentle 3×3 blur for crisp-but-not-jagged edges.
    private static func recolor(_ alpha: AlphaBitmap) -> AlphaBitmap {
        var a = alpha
        a.boost(threshold: 30)
        return a.gaussianBlurred3x3()
    }
}
