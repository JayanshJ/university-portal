import Foundation
import PDFKit

/// A searchable piece of a PDF: a page, or part of a long page, in reading order.
public struct PageChunk: Sendable, Equatable {
    public var page: Int  // 1-based
    public var ordinal: Int
    public var text: String
}

/// PDF text per page, chunked like Study GPT (≈800 characters, 100 overlap) but never across pages,
/// so every chunk can be cited with its page number.
public enum PageText {
    static let target = 800
    static let overlap = 100

    /// One string per page; nil when the file is not a readable PDF.
    public static func pages(of url: URL) -> [String]? {
        guard let document = PDFDocument(url: url) else { return nil }
        return (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
    }

    public static func chunks(pages: [String]) -> [PageChunk] {
        var chunks: [PageChunk] = []
        for (index, raw) in pages.enumerated() {
            let text = clean(raw)
            guard text.count >= 20 else { continue }  // title-only or image-only pages
            for piece in split(text) {
                chunks.append(PageChunk(page: index + 1, ordinal: chunks.count, text: piece))
            }
        }
        return chunks
    }

    /// Joins hyphenated line breaks and collapses whitespace.
    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "-\n", with: "")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A page up to 1.5× the target stays whole; longer pages split at sentence ends with overlap.
    static func split(_ text: String) -> [String] {
        guard text.count > Int(Double(target) * 1.5) else { return [text] }
        let sentences = text.components(separatedBy: ". ")
        var pieces: [String] = []
        var buffer = ""
        for (index, sentence) in sentences.enumerated() {
            let piece = index < sentences.count - 1 ? sentence + "." : sentence
            if !buffer.isEmpty, buffer.count + piece.count + 1 > target {
                pieces.append(buffer)
                buffer = String(buffer.suffix(overlap)) + " " + piece
            } else {
                buffer = buffer.isEmpty ? piece : buffer + " " + piece
            }
        }
        if !buffer.isEmpty { pieces.append(buffer) }
        // A "sentence" can itself be huge (tables, formula dumps): hard-split those.
        return pieces.flatMap { piece -> [String] in
            guard piece.count > target * 2 else { return [piece] }
            return stride(from: 0, to: piece.count, by: target).map { start in
                let from = piece.index(piece.startIndex, offsetBy: start)
                let to = piece.index(from, offsetBy: min(target, piece.count - start))
                return String(piece[from..<to])
            }
        }
    }
}
