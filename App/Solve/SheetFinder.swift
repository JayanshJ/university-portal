import Foundation
import UniversityKit

/// Finds the exercise sheet an assignment is about. Moodle assignments are often only an upload
/// slot ("Abgabe Blatt 4") while the sheet itself is a PDF among the course materials, on Moodle
/// or on CMS, so Solve looks there: same sheet number, sheet-like name, not a solution, posted
/// around the due date.
enum SheetFinder {
    struct Candidate: Identifiable, Hashable {
        var item: PortalOverview.ItemRow
        var score: Int
        var id: Int64 { item.id }
        var name: String { item.title }
    }

    /// Score from which a material is taken without asking.
    static let confident = 60

    /// PDFs of the assignment's course (and CMS courses with a similar name), best match first.
    static func candidates(assignment: String, deadline: PortalOverview.ItemRow?, overview: PortalOverview) -> [Candidate] {
        let courseIds = relatedCourses(deadline, overview: overview)
        let numbers = Self.sheetNumbers(in: assignment)
        let keywords = Self.words(assignment).subtracting(Self.words((deadline?.course ?? "") + " " + (deadline?.courseFullName ?? "")))
        let due = deadline?.date
        return overview.materials
            .filter { courseIds.contains($0.courseId) && $0.hasFile && isPDF($0) }
            .map { item in
                var score = score(item, numbers: numbers, sameCourse: item.courseId == deadline?.courseId, due: due)
                // Shares a distinctive word with the assignment ("Capstone").
                if !keywords.isDisjoint(with: Self.words(item.title + " " + (item.filename ?? ""))) { score += 15 }
                return Candidate(item: item, score: score)
            }
            .sorted { $0.score != $1.score ? $0.score > $1.score : ($0.item.date ?? .distantPast) > ($1.item.date ?? .distantPast) }
    }

    static func best(_ candidates: [Candidate]) -> Candidate? {
        candidates.first.flatMap { $0.score >= confident ? $0 : nil }
    }

    private static func isPDF(_ item: PortalOverview.ItemRow) -> Bool {
        (item.filename ?? item.title).lowercased().hasSuffix(".pdf")
    }

    /// The deadline's course, plus courses whose name shares a distinctive word with it (the CMS
    /// page of the same lecture).
    private static func relatedCourses(_ deadline: PortalOverview.ItemRow?, overview: PortalOverview) -> Set<Int64> {
        guard let deadline else { return Set(overview.courses.filter(\.active).map(\.id)) }
        let words = Self.words(deadline.course + " " + deadline.courseFullName)
        var ids: Set<Int64> = [deadline.courseId]
        for course in overview.courses where course.active {
            if !words.isDisjoint(with: Self.words(course.shortName + " " + course.fullName)) { ids.insert(course.id) }
        }
        return ids
    }

    private static let filler: Set<String> = ["and", "und", "the", "der", "die", "das", "for", "fur", "für", "in", "of", "von",
                                              "sose", "wise", "winter", "summer", "semester", "course", "kurs", "vorlesung", "lecture"]

    private static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count >= 4 && !filler.contains($0) })
    }

    /// Whole numbers in a name, without leading zeros ("Blatt_04" → 4), ignoring years and terms
    /// ("WS26", "2026/27").
    static func numbers(in text: String) -> Set<Int> {
        let cleaned = text.replacingOccurrences(of: #"(?i)(ws|ss|wise|sose|wintersemester|sommersemester)\s*\d{2}(\s*/\s*\d{2})?|\b20\d{2}\b|\b\d{2}/\d{2}\b"#,
                                                with: " ", options: .regularExpression)
        return Set(cleaned.split { !$0.isNumber }.compactMap { Int($0) }.filter { $0 < 100 })
    }

    /// The sheet's number: the one right after a word like "Blatt" or "Assignment" when there is one
    /// ("Prüfungsvorleistung 1 (Übungsblatt 3)" → 3), otherwise every number.
    static func sheetNumbers(in text: String) -> Set<Int> {
        let pattern = #"(?i)(blatt|sheet|assignment|exercise|übung|uebung|aufgabe|serie|homework|capstone|tutorial|problem set|hausaufgabe)[^0-9a-z]{0,3}(\d{1,2})\b"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        let found = regex.matches(in: text, range: range).compactMap { Range($0.range(at: 2), in: text).flatMap { Int(text[$0]) } }
        return found.isEmpty ? numbers(in: text) : Set(found)
    }

    private static let sheetWords = ["blatt", "sheet", "exercise", "übung", "uebung", "aufgabe", "assignment", "homework",
                                     "hausaufgabe", "problem", "serie", "worksheet", "tutorial", "ubung"]
    private static let solutionWords = ["lösung", "loesung", "losung", "solution", "musterl", "answers"]

    private static func score(_ item: PortalOverview.ItemRow, numbers: Set<Int>, sameCourse: Bool, due: Date?) -> Int {
        let name = (item.title + " " + (item.filename ?? "") + " " + (item.section ?? "")).lowercased()
        var score = 0
        if !numbers.isEmpty, !numbers.isDisjoint(with: Self.numbers(in: item.title + " " + (item.filename ?? ""))) { score += 50 }
        if sheetWords.contains(where: name.contains) { score += 25 }
        if solutionWords.contains(where: name.contains) { score -= 60 }
        if sameCourse { score += 5 }
        if let due, let posted = item.date {
            let days = due.timeIntervalSince(posted) / 86_400
            if days >= -1 && days <= 21 { score += 10 }
        }
        return score
    }
}
