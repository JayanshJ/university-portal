import Foundation
import GRDB
import Testing
@testable import UniversityKit

/// Runs the retriever on a COPY of a real database (never the app's own file). Off by default:
/// `UNI_LIVE_DB=/path/to/copy.sqlite swift test --filter LiveIndexTests`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["UNI_LIVE_DB"] != nil))
struct LiveIndexTests {
    @Test func sampleQuestions() throws {
        let queue = try DatabaseQueue(path: ProcessInfo.processInfo.environment["UNI_LIVE_DB"]!)
        let retriever = Retriever(database: try UniDatabase(queue))
        let questions: [(String, [String])] = [
            ("What are the limitations of the alpha miner?", ["alpha miner", "Alpha-Algorithmus", "Petri net", "Petrinetz", "process discovery"]),
            ("Explain tail recursion", ["tail recursion", "Endrekursion", "recursive function", "accumulator"]),
            ("What do we have to do for the DeMIS capstone?", ["capstone", "assignment", "team", "submission", "Abgabe"]),
            ("How are business processes modelled?", ["Geschäftsprozess", "Modellierung", "BPMN", "EPK", "process model"]),
            ("How does a hypothesis test work?", ["Hypothesentest", "hypothesis test", "Nullhypothese", "p-value", "Signifikanzniveau"]),
        ]
        for (question, terms) in questions {
            let excerpts = try retriever.excerpts(for: question, extraTerms: terms)
            print("LIVE \(question) → \(excerpts.count) excerpts: " + excerpts.prefix(4).map { "\($0.course) | \($0.title) p.\($0.page)" }.joined(separator: "; "))
        }
    }
}
