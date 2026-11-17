import Foundation

/// What a sheet asks for on submission. The AI only reports which fields; the values come from stored details.
public struct SubmissionRules: Codable, Sendable, Equatable {
    public enum Field: String, Codable, CaseIterable, Sendable {
        case name, matrikelnr, email, group, tutorial
        /// Only for `missing`: the sheet number a filename pattern needs. Never a header row.
        case sheet
        case partnerNames = "partner_names"
        case partnerMatrikelnr = "partner_matrikelnr"
    }

    public var header: [Field]
    public var filename: String?
    public var other: [String]
    public var quote: String?

    public init(header: [Field], filename: String? = nil, other: [String] = [], quote: String? = nil) {
        self.header = header
        self.filename = filename
        self.other = other
        self.quote = quote
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let raw = (try? c.decode([String].self, forKey: .header)) ?? []
        let fields = raw.compactMap(Field.init(rawValue:)).filter { $0 != .sheet }
        header = fields.isEmpty ? [.name] : fields
        filename = try? c.decode(String?.self, forKey: .filename)
        other = (try? c.decode([String].self, forKey: .other)) ?? []
        quote = try? c.decode(String?.self, forKey: .quote)
    }

    private enum Keys: String, CodingKey { case header, filename, other, quote }

    public static let none = SubmissionRules(header: [.name])

    public static let instructions = """
        Read the sheet and report only what it asks for on submission. Answer with this JSON and nothing else:
        {"header": [...], "filename": null, "other": [], "quote": null}
        - "header": the fields the sheet wants at the top of the submission, from: \
        name, matrikelnr, email, group, tutorial, partner_names, partner_matrikelnr.
        - "filename": the required file name pattern, or null. Use the placeholders \
        {name} {lastname} {firstname} {matrikelnr} {group} {sheet} {course}.
        - "other": any further submission rules, as short strings.
        - "quote": the sentence of the sheet that states these rules, copied verbatim, or null.
        Never write names, numbers or any personal values yourself.
        """

    public static func parse(_ reply: String) -> SubmissionRules {
        guard let open = reply.firstIndex(of: "{"), let close = reply.lastIndex(of: "}"), open < close,
            let rules = try? JSONDecoder().decode(
                SubmissionRules.self, from: Data(reply[open...close].utf8))
        else { return .none }
        return rules
    }

    // MARK: Missing details

    public func missing(student: StudentDetails, course: CourseDetails, sheet: Int?) -> [Field] {
        var needed = header
        var needsFirstname = false
        if let filename, !blank(filename) {
            let map: [String: Field] = [
                "name": .name, "lastname": .name, "matrikelnr": .matrikelnr, "group": .group,
                "tutorial": .tutorial, "email": .email, "sheet": .sheet,
            ]
            for token in Self.tokens(in: filename) {
                if token == "firstname" {
                    needed.append(.name)
                    needsFirstname = true
                } else if let field = map[token] {
                    needed.append(field)
                }
            }
        } else {
            needed.append(.name)  // the fallback filename uses the name
        }
        var result: [Field] = []
        for field in needed where !result.contains(field) {
            let empty: Bool
            switch field {
            case .name:
                empty = blank(student.name)
                    || (needsFirstname && student.name.split(whereSeparator: \.isWhitespace).count < 2)
            case .matrikelnr: empty = blank(student.matrikelnr)
            case .email: empty = blank(student.email)
            case .group: empty = blank(course.group)
            case .tutorial: empty = blank(course.tutorial)
            case .sheet: empty = sheet == nil
            case .partnerNames: empty = course.partners.isEmpty || course.partners.contains { blank($0.name) }
            case .partnerMatrikelnr:
                empty = course.partners.isEmpty || course.partners.contains { blank($0.matrikelnr) }
            }
            if empty { result.append(field) }
        }
        return result
    }

    /// Lowercased placeholder names in a pattern, in order.
    private static func tokens(in pattern: String) -> [String] {
        pattern.matches(of: /\{([^}]*)\}/).map { $0.1.lowercased() }
    }

    private func blank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    // MARK: Header

    /// Whether the sheet's quote is German, so labels follow the sheet's language.
    public var isGerman: Bool {
        guard let quote else { return false }
        let words = Set(
            quote.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty })
        let german: Set<String> = [
            "und", "der", "die", "das", "bitte", "sie", "abgabe", "matrikel", "matrikelnummer",
            "gruppe", "übungsgruppe", "ihre", "blatt", "namen",
        ]
        return !words.isDisjoint(with: german)
    }

    /// A field's short name, for a one-line summary ("Name · Matrikelnr. · Gruppe").
    public func shortLabel(_ field: Field) -> String {
        let de = isGerman
        switch field {
        case .name: return "Name"
        case .matrikelnr: return de ? "Matrikelnr." : "Student ID"
        case .email: return de ? "E-Mail" : "Email"
        case .group: return de ? "Gruppe" : "Group"
        case .tutorial: return de ? "Übungsgruppe" : "Tutorial"
        case .sheet: return de ? "Blatt" : "Sheet"
        case .partnerNames: return "Partner"
        case .partnerMatrikelnr: return de ? "Partner-Matrikelnr." : "Partner IDs"
        }
    }

    public func header(
        student: StudentDetails, course: CourseDetails, courseName: String, sheetTitle: String
    ) -> [(label: String, value: String)] {
        let de = isGerman
        var rows: [(label: String, value: String)] = []
        for field in header {
            switch field {
            case .sheet: continue
            case .name: rows.append(("Name", student.name))
            case .matrikelnr: rows.append((de ? "Matrikelnummer" : "Student ID", student.matrikelnr))
            case .email: rows.append((de ? "E-Mail" : "Email", student.email))
            case .group: rows.append((de ? "Gruppe" : "Group", course.group))
            case .tutorial: rows.append((de ? "Übungsgruppe" : "Tutorial", course.tutorial))
            case .partnerNames:
                rows.append((de ? "Partner" : "Partners", course.partners.map(\.name).joined(separator: ", ")))
            case .partnerMatrikelnr:
                rows.append((
                    de ? "Partner Matrikelnr." : "Partner student IDs",
                    course.partners.map(\.matrikelnr).joined(separator: ", ")
                ))
            }
        }
        rows.append((de ? "Kurs" : "Course", courseName))
        rows.append((de ? "Blatt" : "Sheet", sheetTitle))
        return rows
    }

    // MARK: Filename

    public func filename(
        student: StudentDetails, course: CourseDetails, assignment: String, sheet: Int?, courseShort: String
    ) -> String {
        var name: String
        if let pattern = filename, !blank(pattern) {
            let words = student.name.split(whereSeparator: \.isWhitespace).map(String.init)
            let values: [String: String] = [
                "name": student.name, "lastname": words.last ?? "",
                "firstname": words.dropLast().joined(separator: " "),
                "matrikelnr": student.matrikelnr, "group": course.group, "tutorial": course.tutorial,
                "email": student.email, "sheet": sheet.map(String.init) ?? "", "course": courseShort,
            ]
            name = ""
            var rest = pattern[...]
            while let m = rest.firstMatch(of: /\{([^}]*)\}/) {
                name += rest[..<m.range.lowerBound] + (values[m.1.lowercased()] ?? "")
                rest = rest[m.range.upperBound...]
            }
            name += rest
        } else {
            name = "\(assignment) - \(student.name)"
        }
        name = String(name.map { "/\\:*?\"<>|".contains($0) ? "-" : $0 })
        var stem = name.lowercased().hasSuffix(".pdf") ? String(name.dropLast(4)) : name
        for sep in ["_", "-", " "] {
            while stem.contains(sep + sep) { stem = stem.replacingOccurrences(of: sep + sep, with: sep) }
        }
        stem = stem.trimmingCharacters(in: CharacterSet(charactersIn: "_- "))
        return stem + ".pdf"
    }
}
