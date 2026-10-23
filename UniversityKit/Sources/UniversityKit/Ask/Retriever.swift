import Foundation
import GRDB

/// A passage given to the model, numbered for citations ("[2]").
public struct Excerpt: Sendable, Equatable, Identifiable {
    public var number: Int
    public var itemId: Int64
    public var courseId: Int64
    public var title: String
    public var course: String
    public var page: Int
    public var text: String

    public var id: Int { number }
}

/// Picks the passages for a question. Ported from Study GPT's retrieval (lib/retrieval): explicit
/// material references first ("Übungsblatt 6", "Lecture 02"), then the top 4 materials by best match,
/// neighbouring chunks for context, within a ~6,000-character budget. Ranking is full-text BM25 over
/// the page index instead of embeddings (on-device embeddings did not match English questions to
/// German slides), with the search terms widened by the model beforehand.
public struct Retriever: Sendable {
    public static let budget = 6_000
    static let materialLimit = 4

    let database: UniDatabase

    public init(database: UniDatabase) {
        self.database = database
    }

    /// - Parameters:
    ///   - question: the user's question, used for explicit references and as search terms.
    ///   - extraTerms: more search terms (e.g. the model's English/German expansion).
    ///   - courseId: restrict to one course.
    public func excerpts(for question: String, extraTerms: [String] = [], courseId: Int64? = nil) throws -> [Excerpt] {
        try database.writer.read { db in
            let materials = try Self.materials(db, courseId: courseId)
            guard !materials.isEmpty else { return [] }
            let byId = Dictionary(uniqueKeysWithValues: materials.map { ($0.id, $0) })
            let explicit = MaterialReference.detect(in: question, titles: materials.map { ($0.id, $0.title) })

            // Ranked hits across the selectable materials.
            let terms = Self.searchTerms(question) + extraTerms.flatMap(Self.searchTerms)
            let stems = Self.stems(terms)
            var hits: [Hit] = []
            if let pattern = FTS5Pattern(matchingAnyTokenIn: terms.joined(separator: " ")) {
                hits = try Row.fetchAll(db, sql: """
                    SELECT p.id, p.item_id, p.page, p.ordinal, p.text, bm25(uni_page_fts) AS rank
                    FROM uni_page_fts JOIN uni_page p ON p.id = uni_page_fts.rowid
                    WHERE uni_page_fts MATCH ?
                    ORDER BY rank LIMIT 200
                    """, arguments: [pattern]).compactMap { row -> Hit? in
                    let itemId: Int64 = row["item_id"]
                    guard byId[itemId] != nil else { return nil }
                    return Hit(itemId: itemId, page: row["page"], ordinal: row["ordinal"], text: row["text"], rank: row["rank"])
                }
                // Relevance floor (the counterpart of Study GPT's similarity floor): a page that shares
                // only one loose word with a multi-word question is noise, not a source.
                let needed = min(2, stems.count)
                hits = hits.filter { Self.matchedStems(stems, in: $0.text) >= needed }
            }

            // Material routing: best hit per material → top 4, plus anything named explicitly.
            var selected: [Int64] = []
            for hit in hits where !selected.contains(hit.itemId) {
                selected.append(hit.itemId)
                if selected.count == Self.materialLimit { break }
            }
            for id in explicit where !selected.contains(id) { selected.append(id) }

            var picked: [Hit] = []
            var used = 0
            var seen = Set<String>()
            func add(_ hit: Hit) -> Bool {
                let key = "\(hit.itemId):\(hit.ordinal)"
                guard !seen.contains(key) else { return false }
                if used + hit.text.count > Self.budget, !picked.isEmpty { return false }
                seen.insert(key)
                picked.append(hit)
                used += hit.text.count
                return true
            }

            // (A) Named materials first, in document order (the user asked for that material),
            // starting where it matches the question best if it matches at all.
            if !explicit.isEmpty {
                let slice = max(2_500, Self.budget / explicit.count)
                for id in explicit {
                    let chunks = try Self.chunks(db, itemId: id)
                    let start = hits.first { $0.itemId == id }.flatMap { best in chunks.firstIndex { $0.ordinal == best.ordinal } } ?? 0
                    var taken = 0
                    for chunk in chunks[max(0, start - 1)...] where taken < slice {
                        if add(chunk) { taken += chunk.text.count }
                    }
                }
            }

            // (B) The best hits of the selected materials, each with its neighbours.
            let selectedSet = Set(selected)
            for hit in hits where selectedSet.contains(hit.itemId) && !explicit.contains(hit.itemId) {
                if used >= Self.budget { break }
                guard add(hit) else { continue }
                for neighbour in try Self.neighbours(db, of: hit) { _ = add(neighbour) }
            }

            // Present grouped by material (in selection order), then in reading order.
            let order = Dictionary(uniqueKeysWithValues: selected.enumerated().map { ($1, $0) })
            return picked
                .sorted { (order[$0.itemId] ?? 99, $0.ordinal) < (order[$1.itemId] ?? 99, $1.ordinal) }
                .enumerated()
                .map { index, hit in
                    let material = byId[hit.itemId]!
                    return Excerpt(number: index + 1, itemId: hit.itemId, courseId: material.courseId,
                                   title: material.title, course: material.course, page: hit.page, text: hit.text)
                }
        }
    }

    struct Hit {
        var itemId: Int64
        var page: Int
        var ordinal: Int
        var text: String
        var rank: Double = 0
    }

    struct Material {
        var id: Int64
        var courseId: Int64
        var title: String
        var course: String
    }

    static func materials(_ db: Database, courseId: Int64?) throws -> [Material] {
        try Row.fetchAll(db, sql: """
            SELECT i.id, i.course_id, i.title, c.short_name FROM uni_item i
            JOIN uni_course c ON c.id = i.course_id
            JOIN uni_index x ON x.item_id = i.id AND x.error IS NULL AND x.chunks > 0
            WHERE i.deleted_at IS NULL AND c.active = 1 AND (? IS NULL OR i.course_id = ?)
            """, arguments: [courseId, courseId]).map {
            Material(id: $0["id"], courseId: $0["course_id"], title: $0["title"], course: $0["short_name"])
        }
    }

    static func chunks(_ db: Database, itemId: Int64) throws -> [Hit] {
        try Row.fetchAll(db, sql: "SELECT item_id, page, ordinal, text FROM uni_page WHERE item_id = ? ORDER BY ordinal",
                         arguments: [itemId]).map {
            Hit(itemId: $0["item_id"], page: $0["page"], ordinal: $0["ordinal"], text: $0["text"])
        }
    }

    static func neighbours(_ db: Database, of hit: Hit) throws -> [Hit] {
        try Row.fetchAll(db, sql: """
            SELECT item_id, page, ordinal, text FROM uni_page
            WHERE item_id = ? AND ordinal IN (?, ?) ORDER BY ordinal
            """, arguments: [hit.itemId, hit.ordinal - 1, hit.ordinal + 1]).map {
            Hit(itemId: $0["item_id"], page: $0["page"], ordinal: $0["ordinal"], text: $0["text"])
        }
    }

    /// Distinct, comparable word stems: case- and accent-folded, cut to their first letters so
    /// "recursion" also finds "recursive" while "limitations" doesn't find "Limitsystematiken".
    static func stems(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        return terms.compactMap { term in
            let folded = term.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            let stem = folded.count > 5 ? String(folded.prefix(max(5, folded.count - 3))) : folded
            return seen.insert(stem).inserted ? stem : nil
        }
    }

    static func matchedStems(_ stems: [String], in text: String) -> Int {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return stems.filter { folded.contains($0) }.count
    }

    /// Words worth searching for: 3+ letters (or any number), minus common English and German filler.
    static func searchTerms(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { word in
                (word.count >= 3 || word.allSatisfy(\.isNumber)) && !word.isEmpty && !stopwords.contains(word)
            }
    }

    static let stopwords: Set<String> = [
        "the", "and", "for", "are", "was", "what", "when", "where", "which", "who", "why", "how", "does", "did",
        "can", "could", "should", "would", "this", "that", "these", "those", "with", "from", "about", "into",
        "explain", "tell", "please", "there", "their", "than", "then", "have", "has", "had", "you", "your",
        "der", "die", "das", "und", "ist", "sind", "was", "wie", "wer", "wann", "wo", "warum", "mit", "von",
        "für", "fur", "den", "dem", "des", "ein", "eine", "einen", "einer", "nicht", "auch", "auf", "aus",
        "bei", "noch", "nach", "über", "uber", "zum", "zur", "oder", "kann", "werden", "wird",
    ]
}

/// Detects a material named in the question, by its full title or by "<word> <number>" such as
/// "übungsblatt 6", "sheet 2" or "lecture 01". Ported from Study GPT's detectRefs, including its fuzzy
/// word match for mangled spellings ("bungblatt" ~ "uebungsblatt").
enum MaterialReference {
    static func detect(in question: String, titles: [(Int64, String)]) -> [Int64] {
        let queryTokens = tokens(question)
        let queryNorm = normalize(question)
        var found: [Int64] = []
        for (id, title) in titles {
            let titleTokens = tokens(title)
            let titleNumbers = titleTokens.filter(isNumber).map(stripZeros)
            let titleWords = titleTokens.filter(isWord)
            let titleNorm = normalize(title)
            if titleNorm.count >= 6, queryNorm.contains(titleNorm) {
                found.append(id)
                continue
            }
            for (index, token) in queryTokens.enumerated() where isNumber(token) && titleNumbers.contains(stripZeros(token)) {
                // The nearest word before the number qualifies it; a bare number is too ambiguous.
                let qualifier = queryTokens[max(0, index - 3)..<index].reversed().first(where: isWord)
                if let qualifier, titleWords.contains(where: { fuzzy($0, qualifier) }) {
                    found.append(id)
                    break
                }
            }
        }
        return found
    }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: #"\.(pdf|pptx?|docx?|zip)$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func tokens(_ text: String) -> [String] {
        // Split letters from digits too: "Lecture_01" and "Lecture01" both give "lecture", "01".
        normalize(text)
            .replacingOccurrences(of: #"([a-z])([0-9])|([0-9])([a-z])"#, with: "$1$3 $2$4", options: .regularExpression)
            .split(separator: " ").map(String.init)
    }

    static func isNumber(_ token: String) -> Bool { !token.isEmpty && token.allSatisfy(\.isNumber) }
    static func isWord(_ token: String) -> Bool { token.count >= 4 && token.contains(where: \.isLetter) }
    static func stripZeros(_ number: String) -> String { String(Int(number) ?? -1) }

    static func fuzzy(_ a: String, _ b: String) -> Bool {
        if a.contains(b) || b.contains(a) { return true }
        guard a.count >= 5, b.count >= 5 else { return false }
        let (hay, needle) = a.count >= b.count ? (a, b) : (b, a)
        var index = needle.startIndex
        for character in hay where character == needle[index] {
            index = needle.index(after: index)
            if index == needle.endIndex { return true }
        }
        return false
    }
}
