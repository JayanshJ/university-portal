import Foundation

/// A streamed reply of the form `note <solution>…</solution> <sources>…</sources>`.
public struct SolveReply: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case excerpt(Int)
        case memory(String)
    }

    public var note: String
    public var solution: String?
    public var sources: [Source]

    public init(note: String, solution: String? = nil, sources: [Source] = []) {
        self.note = note
        self.solution = solution
        self.sources = sources
    }

    /// Splits a (possibly partial) reply. A tag that is still arriving is hidden, and nothing from
    /// `<sources>` ever enters the note or the solution.
    public static func parse(_ raw: String) -> SolveReply {
        let trim = CharacterSet.whitespacesAndNewlines
        guard let open = raw.range(of: "<solution>") else {
            var note = raw
            var sources: [Source] = []
            if let tag = note.range(of: "<sources>") {
                sources = parseSources(String(note[tag.upperBound...]))
                note = String(note[..<tag.lowerBound])
            } else {
                note = hidingPartialTag(note, of: ["<solution>", "<sources>"])
            }
            return SolveReply(note: note.trimmingCharacters(in: trim), solution: nil, sources: sources)
        }
        let note = String(raw[..<open.lowerBound]).trimmingCharacters(in: trim)
        var body = String(raw[open.upperBound...])
        var sources: [Source] = []
        if let close = body.range(of: "</solution>") {
            let tail = String(body[close.upperBound...])
            body = String(body[..<close.lowerBound])
            if let tag = tail.range(of: "<sources>") { sources = parseSources(String(tail[tag.upperBound...])) }
        } else {
            body = hidingPartialTag(body, of: ["</solution>"])
        }
        return SolveReply(note: note, solution: body.trimmingCharacters(in: .newlines), sources: sources)
    }

    private static func hidingPartialTag(_ text: String, of tags: [String]) -> String {
        guard let lt = text.lastIndex(of: "<") else { return text }
        let tail = text[lt...]
        return tags.contains { $0.hasPrefix(tail) } ? String(text[..<lt]) : text
    }

    private static func parseSources(_ text: String) -> [Source] {
        var text = text
        if let close = text.range(of: "</sources>") { text = String(text[..<close.lowerBound]) }
        var result: [Source] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]"), let number = Int(line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)) {
                result.append(.excerpt(number))
            } else if line.lowercased().hasPrefix("memory:") {
                let title = line.dropFirst("memory:".count).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { result.append(.memory(title)) }
            }
        }
        return result
    }
}
