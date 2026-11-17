import Foundation

/// Picks course material for an assignment sheet, one retrieval per task.
public struct SolveContext {
    static let queryLimit = 2_000

    /// Excerpts for every task in every course, each page once. Numbers continue after the
    /// excerpts already sent (`already` holds their "itemId:page" keys), starting at 1.
    public static func excerpts(retriever: Retriever, tasks: [String], courseIds: [Int64], already: Set<String>) throws -> [Excerpt] {
        var seen = already
        var result: [Excerpt] = []
        var number = already.count
        for task in tasks {
            for courseId in courseIds {
                for var excerpt in try retriever.excerpts(for: task, courseId: courseId) {
                    guard seen.insert("\(excerpt.itemId):\(excerpt.page)").inserted else { continue }
                    number += 1
                    excerpt.number = number
                    result.append(excerpt)
                }
            }
        }
        return result
    }

    /// The sheet split at "Aufgabe 1", "Task 2", "Exercise 3", "Problem 4" or "1." / "2)" lines; the
    /// whole text (capped) when nothing matches.
    public static func tasks(in sheetText: String) -> [String] {
        let marker = try! NSRegularExpression(pattern: #"^\s*(?:(?:Aufgabe|Task|Exercise|Problem)\s*\d+|\d+[.)])"#, options: [.caseInsensitive])
        var tasks: [String] = []
        var current: [String] = []
        var found = false
        for line in sheetText.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            if marker.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                found = true
                if !current.isEmpty { tasks.append(current.joined(separator: "\n")) }
                current = [text]
            } else if found {
                current.append(text)
            }
        }
        if found, !current.isEmpty { tasks.append(current.joined(separator: "\n")) }
        let cleaned = tasks.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let result = cleaned.isEmpty ? [sheetText.trimmingCharacters(in: .whitespacesAndNewlines)] : cleaned
        return result.filter { !$0.isEmpty }.map { String($0.prefix(queryLimit)) }
    }
}
