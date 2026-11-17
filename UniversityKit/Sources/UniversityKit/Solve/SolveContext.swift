import Foundation

/// Picks course material for an assignment sheet, one retrieval per task.
public struct SolveContext {
    static let queryLimit = 2_000

    /// The most excerpt text one Solve sends, over its first reply and all follow-ups.
    public static let excerptBudget = 50_000

    /// Excerpts for every task in every course, each page once. Numbers continue after the
    /// excerpts already sent (`already` holds their "itemId:page" keys), starting at 1.
    /// At most `budget` characters of excerpt text: each task's best excerpts come first (rank 1
    /// of every task and course, then rank 2, ...), and the ones kept stay in task order.
    public static func excerpts(retriever: Retriever, tasks: [String], courseIds: [Int64], already: Set<String>,
                                budget: Int = excerptBudget) throws -> [Excerpt] {
        var lists: [[Excerpt]] = []
        for task in tasks {
            for courseId in courseIds { lists.append(try retriever.excerpts(for: task, courseId: courseId)) }
        }
        return pick(lists, already: already, budget: budget)
    }

    /// Picks from ranked lists (in task order) within the budget, then numbers what it kept.
    static func pick(_ lists: [[Excerpt]], already: Set<String>, budget: Int) -> [Excerpt] {
        var seen = already
        var kept = Set<[Int]>()  // [list, rank]
        var used = 0
        let depth = lists.map(\.count).max() ?? 0
        for rank in 0..<depth {
            for (list, excerpts) in lists.enumerated() where rank < excerpts.count {
                let excerpt = excerpts[rank]
                guard used + excerpt.text.count <= budget, seen.insert("\(excerpt.itemId):\(excerpt.page)").inserted else { continue }
                used += excerpt.text.count
                kept.insert([list, rank])
            }
        }
        var result: [Excerpt] = []
        var number = already.count
        for (list, excerpts) in lists.enumerated() {
            for (rank, var excerpt) in excerpts.enumerated() where kept.contains([list, rank]) {
                number += 1
                excerpt.number = number
                result.append(excerpt)
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
