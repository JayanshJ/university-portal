import Foundation

/// A line of Markdown cut at its formulas (`$…$` and `$$…$$`), so a renderer can style the prose
/// and keep the math exactly as written.
public enum MathSpans {
    public enum Span: Equatable, Sendable {
        case text(String)
        /// The whole formula with its dollar signs.
        case math(String)
    }

    /// `\$` stays text; a `$` or `$$` that is never closed is text too.
    public static func split(_ line: String) -> [Span] {
        var spans: [Span] = []
        var text = ""
        var index = line.startIndex
        while index < line.endIndex {
            let char = line[index]
            if char == "\\", line.index(after: index) < line.endIndex, line[line.index(after: index)] == "$" {
                text += "\\$"
                index = line.index(index, offsetBy: 2)
                continue
            }
            guard char == "$" else {
                text.append(char)
                index = line.index(after: index)
                continue
            }
            let delimiter = line[index...].hasPrefix("$$") ? "$$" : "$"
            let start = line.index(index, offsetBy: delimiter.count)
            guard start <= line.endIndex, let close = closing(delimiter, in: line, from: start) else {
                text.append(char)
                index = line.index(after: index)
                continue
            }
            if !text.isEmpty { spans.append(.text(text)); text = "" }
            let end = line.index(close, offsetBy: delimiter.count)
            spans.append(.math(String(line[index..<end])))
            index = end
        }
        if !text.isEmpty { spans.append(.text(text)) }
        return spans
    }

    /// Where the closing delimiter starts: not escaped, and a formula is never empty.
    private static func closing(_ delimiter: String, in line: String, from start: String.Index) -> String.Index? {
        var index = start
        while index < line.endIndex {
            if line[index] == "\\" {
                index = line.index(index, offsetBy: 2, limitedBy: line.endIndex) ?? line.endIndex
                continue
            }
            if line[index...].hasPrefix(delimiter) { return index > start ? index : nil }
            index = line.index(after: index)
        }
        return nil
    }
}
