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

    /// The glyph library: the student's handwriting (the debug check points it at a synthetic one).
    nonisolated(unsafe) static var library: URL = HandwritingProfile.folder

    static var isSetUp: Bool { HandwritingProfile.readMetadata(at: library.appending(path: "metadata.json")) != nil }

    /// The characters the student's handwriting has, for the conversion prompt.
    static var characters: String {
        (HandwritingProfile.readMetadata(at: library.appending(path: "metadata.json")) ?? [:]).keys.sorted().joined()
    }

    /// Renders markup into handwritten pages. With `strict`, markup with validation errors isn't
    /// rendered; the errors come back as `.invalidMarkup` (only `markup` is validated, never the header).
    ///
    /// `header` rows go above the solution as `Label: value` lines in the same handwriting. When the
    /// handwriting lacks one of their characters (or a value holds markup syntax), the solution is
    /// written below some free space and the header is typed onto page 1 instead.
    static func render(_ markup: String, strict: Bool, header: [(label: String, value: String)] = [],
                       library folder: URL = library) async throws -> Rendering {
        guard HandwritingProfile.readMetadata(at: folder.appending(path: "metadata.json")) != nil else { throw Failure.notSetUp }
        let lines = header.map { "\($0.label): \($0.value)" }
        return try await Task.detached(priority: .userInitiated) {
            let library: GlyphLibrary
            do {
                library = try GlyphLibrary.load(from: folder)
            } catch {
                throw Failure.failed("Your handwriting couldn't be loaded: \(error.localizedDescription)")
            }
            let validation = HandwritingRenderer.validate(markup, library: library)
            if strict && !validation.errors.isEmpty { throw Failure.invalidMarkup(validation.errors) }

            let known = Set((HandwritingProfile.readMetadata(at: folder.appending(path: "metadata.json")) ?? [:]).keys.compactMap(\.first))
            let handwrittenHeader = lines.allSatisfy { canWrite($0, known: known) }
            let text: String
            if lines.isEmpty {
                text = markup
            } else if handwrittenHeader {
                text = lines.joined(separator: "\n") + "\n\n" + markup
            } else {
                text = String(repeating: "\n", count: blankLines(forStamp: lines.count)) + markup
            }
            let (pages, dropped) = HandwritingRenderer.render(text, library: library)
            guard !pages.isEmpty else { throw Failure.failed("Nothing to write.") }

            let folder = FileManager.default.temporaryDirectory.appending(path: "handwriting-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let pdf = folder.appending(path: "handwritten.pdf")
            var data = HandwritingRenderer.pdf(pages)
            if !handwrittenHeader { data = try stamp(header, onto: data) }
            try data.write(to: pdf)
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

    /// Whether a header line can be written by hand as it is: every character has a glyph, and
    /// nothing in it reads as Math Writer markup.
    nonisolated static func canWrite(_ line: String, known: Set<Character>) -> Bool {
        guard !line.contains("~~"), !line.contains(where: { "[]|\\^_".contains($0) }) else { return false }
        return line.allSatisfy { $0 == " " || known.contains($0) }
    }

    // MARK: - Typed header on handwritten pages

    static let stampFont: CGFloat = 10
    static let stampLine: CGFloat = 13
    /// The handwritten page's top and left margins, in points (85 and 80 px at 200 dpi).
    static let stampTop: CGFloat = 85 * 72 / 200
    static let stampLeft: CGFloat = 80 * 72 / 200

    /// Empty markup lines that leave room for a typed header of `rows` rows: an empty line moves
    /// the pen down by 1.25 line heights (80 px = 28.8 pt).
    nonisolated static func blankLines(forStamp rows: Int) -> Int {
        Int((CGFloat(rows) * stampLine + 10) / 28.8) + 1
    }

    /// The PDF with the header typed onto page 1, as two columns at the top margin.
    nonisolated static func stamp(_ header: [(label: String, value: String)], onto pdf: Data) throws -> Data {
        guard let provider = CGDataProvider(data: pdf as CFData), let document = CGPDFDocument(provider) else {
            throw Failure.failed("The handwritten PDF couldn't be read.")
        }
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw Failure.failed("The PDF couldn't be written.") }
        let bold = NSFont.systemFont(ofSize: stampFont, weight: .semibold)
        let regular = NSFont.systemFont(ofSize: stampFont)
        func line(_ text: String, _ font: NSFont) -> CTLine {
            CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black]))
        }
        let labels = header.map { line($0.label, bold) }
        let values = header.map { line($0.value, regular) }
        let column = (labels.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) }.max() ?? 0) + 14
        for number in 1...max(1, document.numberOfPages) {
            guard let page = document.page(at: number) else { continue }
            var box = page.getBoxRect(.mediaBox)
            context.beginPage(mediaBox: &box)
            context.drawPDFPage(page)
            if number == 1 {
                for (index, (label, value)) in zip(labels, values).enumerated() {
                    let baseline = box.maxY - stampTop - stampFont - CGFloat(index) * stampLine
                    context.textPosition = CGPoint(x: box.minX + stampLeft, y: baseline)
                    CTLineDraw(label, context)
                    context.textPosition = CGPoint(x: box.minX + stampLeft + column, y: baseline)
                    CTLineDraw(value, context)
                }
            }
            context.endPage()
        }
        context.closePDF()
        return output as Data
    }

    /// Math Writer's MARKUP.md, bundled: the format the handwriting conversion writes.
    static let markupGuide: String = {
        guard let url = Bundle.main.url(forResource: "MathWriterMarkup", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }()
}
