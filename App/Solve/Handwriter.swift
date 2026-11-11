import AppKit
import Foundation

/// Writes Math Writer markup in the student's own handwriting (HandwritingProfile), with the
/// renderer ported from Math Writer (App/Handwriting). Runs off the main thread.
enum Handwriter {
    struct Rendering: Equatable {
        var pdf: URL
        var pages: [URL]
        /// Characters there's no glyph for, which were left out.
        var dropped: [String]
    }

    enum Failure: LocalizedError, Equatable {
        case notSetUp
        case invalidMarkup([String])
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notSetUp: "Your handwriting isn't set up yet."
            case .invalidMarkup(let errors): "The handwriting markup has errors: \(errors.prefix(3).joined(separator: "; "))"
            case .failed(let message): message
            }
        }
    }

    static var isSetUp: Bool { HandwritingProfile.readMetadata() != nil }

    /// The characters the student's handwriting has, for the conversion prompt.
    static var characters: String {
        (HandwritingProfile.readMetadata() ?? [:]).keys.sorted().joined()
    }

    /// Renders markup into handwritten pages. With `strict`, markup with validation errors isn't
    /// rendered; the errors come back as `.invalidMarkup`.
    static func render(_ markup: String, strict: Bool) async throws -> Rendering {
        guard isSetUp else { throw Failure.notSetUp }
        return try await Task.detached(priority: .userInitiated) {
            let library: GlyphLibrary
            do {
                library = try GlyphLibrary.load(from: HandwritingProfile.folder)
            } catch {
                throw Failure.failed("Your handwriting couldn't be loaded: \(error.localizedDescription)")
            }
            let validation = HandwritingRenderer.validate(markup, library: library)
            if strict && !validation.errors.isEmpty { throw Failure.invalidMarkup(validation.errors) }
            let (pages, dropped) = HandwritingRenderer.render(markup, library: library)
            guard !pages.isEmpty else { throw Failure.failed("Nothing to write.") }

            let folder = FileManager.default.temporaryDirectory.appending(path: "handwriting-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let pdf = folder.appending(path: "handwritten.pdf")
            try HandwritingRenderer.pdf(pages).write(to: pdf)
            var previews: [URL] = []
            for (index, page) in pages.enumerated() {
                let url = folder.appending(path: "p\(index + 1).jpg")
                let bitmap = NSBitmapImageRep(cgImage: page)
                try bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85])?.write(to: url)
                previews.append(url)
            }
            return Rendering(pdf: pdf, pages: previews, dropped: dropped.keys.map(String.init).sorted())
        }.value
    }

    /// Math Writer's MARKUP.md, bundled: the format the handwriting conversion writes.
    static let markupGuide: String = {
        guard let url = Bundle.main.url(forResource: "MathWriterMarkup", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }()
}
