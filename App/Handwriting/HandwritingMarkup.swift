import Foundation

/// Tokenizer for Math Writer's inline markup (port of `render.tokenize`).
enum HandwritingMarkup {
    enum Token: Equatable {
        case text(String)
        case matrix(rows: [[String]], dividers: [Int])
        case frac(num: String, den: String)
        case sum(lower: String, upper: String)
        case integralBounded(lower: String, upper: String)
        case box(String)
        case table(rows: [[String]])
        case strike(String)
        case vec(String)
        case hat(String)
        case sqrt(String)
        case down(String)
        case up(String)
        case arrow
        case approx
        case integral
    }

    static let tags: Set<Character> = Set("MFSBTXVHRDUI")
    /// Marker standing in for a newline inside a multi-line block.
    static let marker: Character = "\u{01}"

    /// A `[X]body[/X]` match, X in `tags`: the first closing tag of the same
    /// letter ends it (the regex `\[(X)\](.*?)\[/\1\]` with DOTALL).
    struct TagMatch {
        var tag: Character
        var range: Range<Int>
        var body: Range<Int>
    }

    static func tagMatches(_ chars: [Character], tags: Set<Character>) -> [TagMatch] {
        var out: [TagMatch] = []
        let n = chars.count
        var i = 0
        while i + 2 < n {
            if chars[i] == "[", chars[i + 2] == "]", tags.contains(chars[i + 1]) {
                let tag = chars[i + 1]
                var j = i + 3
                var found: Int?
                while j + 3 < n {
                    if chars[j] == "[", chars[j + 1] == "/", chars[j + 2] == tag, chars[j + 3] == "]" {
                        found = j
                        break
                    }
                    j += 1
                }
                if let j = found {
                    out.append(TagMatch(tag: tag, range: i..<(j + 4), body: (i + 3)..<j))
                    i = j + 4
                    continue
                }
            }
            i += 1
        }
        return out
    }

    /// Split on the first un-backslash-escaped `sep`; `(s, "")` if absent.
    static func splitUnescaped(_ s: String, _ sep: Character) -> (String, String) {
        let c = Array(s)
        var i = 0
        while i < c.count {
            if c[i] == "\\" && i + 1 < c.count { i += 2; continue }
            if c[i] == sep { return (String(c[..<i]), String(c[(i + 1)...])) }
            i += 1
        }
        return (s, "")
    }

    static func strip(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func limits(_ body: String) -> (String, String) {
        let (a, b) = splitUnescaped(body, "|")
        return (strip(a.replacingOccurrences(of: "\\|", with: "|")),
                strip(b.replacingOccurrences(of: "\\|", with: "|")))
    }

    static func tokenize(_ paragraph: String) -> [Token] {
        let chars = Array(paragraph)
        var tokens: [Token] = []
        var pos = 0
        for m in tagMatches(chars, tags: tags) {
            if m.range.lowerBound > pos { tokens.append(.text(String(chars[pos..<m.range.lowerBound]))) }
            let body = String(chars[m.body])
            switch m.tag {
            case "M":
                // A cell of `|` marks an augmented-matrix divider before the next column.
                var rows: [[String]] = []
                var dividers = Set<Int>()
                for row in body.split(separator: ";", omittingEmptySubsequences: false) {
                    var clean: [String] = []
                    for cell in row.split(separator: ",", omittingEmptySubsequences: false) {
                        let c = strip(String(cell))
                        if c == "|" { dividers.insert(clean.count) } else { clean.append(c) }
                    }
                    rows.append(clean)
                }
                tokens.append(.matrix(rows: rows, dividers: dividers.sorted()))
            case "F":
                let (n, d) = limits(body)
                tokens.append(.frac(num: n, den: d))
            case "S":
                let (lo, up) = limits(body)
                tokens.append(.sum(lower: lo, upper: up))
            case "I":
                let (lo, up) = limits(body)
                tokens.append(.integralBounded(lower: lo, upper: up))
            case "B":
                tokens.append(.box(strip(body)))
            case "T":
                var rows: [[String]] = []
                let lines = strip(body.replacingOccurrences(of: String(marker), with: "\n"))
                for line in lines.split(separator: "\n", omittingEmptySubsequences: false) {
                    if strip(String(line)).isEmpty { continue }
                    rows.append(line.split(separator: "|", omittingEmptySubsequences: false).map { strip(String($0)) })
                }
                tokens.append(.table(rows: rows))
            case "X": tokens.append(.strike(body))
            case "V": tokens.append(.vec(body))
            case "H": tokens.append(.hat(body))
            case "R": tokens.append(.sqrt(body))
            case "D": tokens.append(.down(body))
            case "U": tokens.append(.up(body))
            default: break
            }
            pos = m.range.upperBound
        }
        if pos < chars.count { tokens.append(.text(String(chars[pos...]))) }

        // Pull inline arrows, ≈ and ∫ out of the text runs.
        var expanded: [Token] = []
        for tok in tokens {
            guard case .text(let content) = tok else { expanded.append(tok); continue }
            let c = Array(content)
            var run: [Character] = []
            func flush() {
                if !run.isEmpty { expanded.append(.text(String(run))); run.removeAll() }
            }
            var i = 0
            while i < c.count {
                if i + 1 < c.count, c[i + 1] == ">", c[i] == "-" || c[i] == "=" {
                    flush(); expanded.append(.arrow); i += 2; continue
                }
                switch c[i] {
                case "⇒", "→": flush(); expanded.append(.arrow)
                case "≈": flush(); expanded.append(.approx)
                case "∫": flush(); expanded.append(.integral)
                default: run.append(c[i])
                }
                i += 1
            }
            flush()
        }
        return expanded
    }
}
