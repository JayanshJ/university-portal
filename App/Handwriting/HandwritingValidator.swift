import Foundation

/// Pre-render checks for handwriting markup (port of Math Writer's `validate.py`):
/// the recurring mistakes from MARKUP.md, tag balance, `|` separators, and
/// characters that would be silently dropped.
enum HandwritingValidator {
    private static let tags: [Character] = Array("MFSBTXVHRDUI")

    private static func isAsciiUpper(_ c: Character) -> Bool { c.isASCII && c.isUppercase }
    private static func isAsciiAlnum(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber) }

    /// A bad pattern: returns the match length at position i, or nil.
    private struct BadPattern: Sendable {
        var severityIsError: Bool
        var message: String
        var match: @Sendable ([Character], Int) -> Int?
    }

    private static func literal(_ s: String) -> @Sendable ([Character], Int) -> Int? {
        let p = Array(s)
        return { c, i in
            guard i + p.count <= c.count else { return nil }
            return Array(c[i..<(i + p.count)]) == p ? p.count : nil
        }
    }

    private static let badPatterns: [BadPattern] = [
        BadPattern(severityIsError: true, message: "'=/=' renders as literal chars — use '≠'", match: literal("=/=")),
        BadPattern(severityIsError: true, message: "'=!=' renders as literal chars — use '≠'", match: literal("=!=")),
        BadPattern(severityIsError: true, message: "'lim_(...)' renders literally — use 'lim[D]...[/D]'", match: literal("lim_(")),
        BadPattern(severityIsError: true, message: "'∫[D]a[/D][U]b[/U]' misplaces limits — use '[I]a|b[/I]'", match: literal("∫[D]")),
        BadPattern(severityIsError: true, message: "'Σ[D]..[/D]' misplaces limits — use '[S]lower|upper[/S]'", match: literal("Σ[D]")),
        BadPattern(severityIsError: false, message: "bare '√' before content has no overbar — use '[R]content[/R]'",
                   match: { c, i in
                       i + 1 < c.count && c[i] == "√" && (isAsciiAlnum(c[i + 1]) || c[i + 1] == "(") ? 2 : nil
                   }),
        BadPattern(severityIsError: false, message: "caret '^' renders literally — use Unicode superscript or [U]...[/U]",
                   match: { c, i in
                       i + 1 < c.count && (isAsciiAlnum(c[i]) || c[i] == ")") && c[i + 1] == "^" ? 2 : nil
                   }),
    ]

    /// Python `repr()` of a string, for messages.
    static func pyRepr(_ s: String) -> String {
        let quote: Character = s.contains("'") && !s.contains("\"") ? "\"" : "'"
        var out = String(quote)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if Character(scalar) == quote {
                    out += "\\\(quote)"
                } else if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\x%02x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out.append(quote)
        return out
    }

    private static func lineNumber(_ c: [Character], _ pos: Int) -> Int {
        c[..<pos].reduce(1) { $0 + ($1 == "\n" ? 1 : 0) }
    }

    /// `\[([A-Z])\]` at i → tag letter.
    private static func openTag(_ c: [Character], _ i: Int) -> Character? {
        i + 2 < c.count && c[i] == "[" && c[i + 2] == "]" && isAsciiUpper(c[i + 1]) ? c[i + 1] : nil
    }

    /// `\[/([A-Z])\]` at i → tag letter.
    private static func closeTag(_ c: [Character], _ i: Int) -> Character? {
        i + 3 < c.count && c[i] == "[" && c[i + 1] == "/" && c[i + 3] == "]" && isAsciiUpper(c[i + 2]) ? c[i + 2] : nil
    }

    static func validate(_ text: String, known: Set<Character>) -> HandwritingRenderer.Validation {
        var errors: [String] = []
        var warnings: [String] = []
        let c = Array(text)

        // 1. Known bad patterns.
        for pattern in badPatterns {
            var i = 0
            while i < c.count {
                guard let len = pattern.match(c, i) else { i += 1; continue }
                let near = String(c[max(0, i - 15)..<min(c.count, i + len + 10)])
                let msg = "line \(lineNumber(c, i)): \(pattern.message)  [near: \(pyRepr(near))]"
                if pattern.severityIsError { errors.append(msg) } else { warnings.append(msg) }
                i += len
            }
        }

        // 2. Tag balance.
        var openCounts: [Character: Int] = [:]
        var closeCounts: [Character: Int] = [:]
        var i = 0
        while i < c.count {
            if let t = openTag(c, i) { openCounts[t, default: 0] += 1; i += 3; continue }
            i += 1
        }
        i = 0
        while i < c.count {
            if let t = closeTag(c, i) { closeCounts[t, default: 0] += 1; i += 4; continue }
            i += 1
        }
        for t in tags {
            let o = openCounts[t] ?? 0, cl = closeCounts[t] ?? 0
            if o != cl { errors.append("unbalanced [\(t)] tags: \(o) open vs \(cl) close") }
        }

        // 3. [F]/[S]/[I] bodies need exactly one unescaped top-level '|'.
        for tag in "FSI" {
            for m in HandwritingMarkup.tagMatches(c, tags: [tag]) {
                let body = Array(c[m.body])
                var depth = 0, unescaped = 0, k = 0
                while k < body.count {
                    if body[k] == "\\" && k + 1 < body.count { k += 2; continue }
                    if let t = openTag(body, k), tags.contains(t) { depth += 1; k += 3; continue }
                    if let t = closeTag(body, k), tags.contains(t) { depth -= 1; k += 4; continue }
                    if body[k] == "|" && depth == 0 { unescaped += 1 }
                    k += 1
                }
                let line = lineNumber(c, m.range.lowerBound)
                let preview = pyRepr(String(body.prefix(40)))
                if unescaped == 0 {
                    errors.append("line \(line): [\(tag)] body has no '|' separator: \(preview)")
                } else if unescaped > 1 {
                    warnings.append("line \(line): [\(tag)] body has \(unescaped) unescaped '|' — only the first splits; escape literal bars as \\| : \(preview)")
                }
            }
        }

        // 4. Characters that will silently disappear.
        var plainChars: [Character] = []
        i = 0
        while i < c.count {
            if openTag(c, i) != nil { i += 3; continue }
            if closeTag(c, i) != nil { i += 4; continue }
            plainChars.append(c[i])
            i += 1
        }
        let plain = String(plainChars)
            .replacingOccurrences(of: "~~", with: "")
            .replacingOccurrences(of: "\\|", with: "|")
        var unknown: [(Character, Int)] = []
        var index: [Character: Int] = [:]
        for ch in plain {
            if HandwritingCharset.whitespace.contains(ch) || known.contains(ch)
                || HandwritingCharset.procedural.contains(ch) || HandwritingCharset.subSup.contains(ch)
                || HandwritingCharset.fallbacks[ch] != nil { continue }
            if let at = index[ch] { unknown[at].1 += 1 } else { index[ch] = unknown.count; unknown.append((ch, 1)) }
        }
        let sorted = unknown.enumerated().sorted { a, b in
            a.element.1 != b.element.1 ? a.element.1 > b.element.1 : a.offset < b.offset
        }.map(\.element)
        for (ch, count) in sorted {
            let code = String(format: "%04X", ch.unicodeScalars.first?.value ?? 0)
            errors.append("char \(pyRepr(String(ch))) (U+\(code)) ×\(count) has NO glyph and NO fallback — it will be silently dropped")
        }
        return HandwritingRenderer.Validation(errors: errors, warnings: warnings)
    }
}
