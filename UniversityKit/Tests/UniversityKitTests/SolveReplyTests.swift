import Foundation
import GRDB
import Testing
@testable import UniversityKit

@Suite struct SolveReplyTests {
    @Test func sourcesAreReadAndKeptOutOfTheSolution() {
        let raw = "Done.\n<solution>\n## Aufgabe 1\nx = 2\n</solution>\n<sources>\n[3]\nmemory: Grading rules\n[1]\n</sources>"
        let reply = SolveReply.parse(raw)
        #expect(reply.note == "Done.")
        #expect(reply.solution == "## Aufgabe 1\nx = 2")
        #expect(reply.sources == [.excerpt(3), .memory("Grading rules"), .excerpt(1)])
    }

    @Test func partialSourcesTagIsHiddenWhileStreaming() {
        let solution = "Done.\n<solution>\nbody\n</solution>\n"
        for partial in ["<", "<sour", "<sources"] {
            let reply = SolveReply.parse(solution + partial)
            #expect(reply.solution == "body")
            #expect(reply.sources.isEmpty)
        }
        let open = SolveReply.parse(solution + "<sources>\n[2]\nmemo")
        #expect(open.solution == "body")
        #expect(open.sources == [.excerpt(2)])
        #expect(SolveReply.parse("Answer <sources").note == "Answer")
    }

    @Test func oldRepliesWithoutSourcesStillParse() {
        #expect(SolveReply.parse("Hi there") == SolveReply(note: "Hi there"))
        #expect(SolveReply.parse("Hi there <sol").note == "Hi there")
        #expect(SolveReply.parse("Hi <b>bold</b").note == "Hi <b>bold</b")
        #expect(SolveReply.parse("Hi <solution>").solution == "")
        let streaming = SolveReply.parse("Note.\n<solution>\nStep 1\n</solu")
        #expect(streaming.note == "Note.")
        #expect(streaming.solution == "Step 1")
        let full = SolveReply.parse("Note.\n\n<solution>\n\nStep 1\nStep 2\n\n</solution>\ntrailing")
        #expect(full.solution == "Step 1\nStep 2")
        #expect(full.sources.isEmpty)
        #expect(SolveReply.parse("a < b <solution>x").solution == "x")
        #expect(SolveReply.parse("<solution>\nif a <").solution == "if a ")
    }

    @Test func tasksSplitOnAufgabeAndNumbers() {
        let sheet = "Blatt 6\nAufgabe 1: Modellieren\nmehr Text\nAufgabe 2: Gateways\n"
        #expect(SolveContext.tasks(in: sheet) == ["Aufgabe 1: Modellieren\nmehr Text", "Aufgabe 2: Gateways"])
        #expect(SolveContext.tasks(in: "1. Foo\n2) Bar") == ["1. Foo", "2) Bar"])
        #expect(SolveContext.tasks(in: "Task 1 a\nExercise 2 b\nProblem 3 c").count == 3)
        #expect(SolveContext.tasks(in: "no markers here") == ["no markers here"])
        let long = String(repeating: "x", count: 5_000)
        #expect(SolveContext.tasks(in: long).first?.count == 2_000)
    }

    @Test func excerptsAreDedupedAcrossCoursesAndRenumbered() throws {
        let (database, process, _, _) = try indexedDatabase()
        let courses: [Int64] = try database.writer.read { try Int64.fetchAll($0, sql: "SELECT id FROM uni_course ORDER BY id") }
        let retriever = Retriever(database: database)
        let tasks = ["limitations of the alpha miner", "alpha miner algorithm limitations"]

        let excerpts = try SolveContext.excerpts(retriever: retriever, tasks: tasks, courseIds: courses, already: [])
        #expect(!excerpts.isEmpty)
        #expect(excerpts.map(\.number) == Array(1...excerpts.count))
        let keys = excerpts.map { "\($0.itemId):\($0.page)" }
        #expect(Set(keys).count == keys.count)
        #expect(excerpts.first?.itemId == process)

        let more = try SolveContext.excerpts(retriever: retriever, tasks: tasks, courseIds: courses, already: Set(keys))
        #expect(more.isEmpty)
        let partial = try SolveContext.excerpts(retriever: retriever, tasks: tasks, courseIds: courses, already: [keys[0]])
        #expect(partial.map(\.number) == Array(2...(partial.count + 1)))
        #expect(!partial.contains { "\($0.itemId):\($0.page)" == keys[0] })
    }

    @Test func excerptTextIsCappedKeepingEachTasksBest() {
        func excerpt(_ item: Int64, _ size: Int) -> Excerpt {
            Excerpt(number: 0, itemId: item, courseId: 1, title: "F\(item)", course: "C", page: 1, text: String(repeating: "x", count: size))
        }
        // Two tasks, three ranked excerpts each; room for four.
        let lists = [[excerpt(1, 100), excerpt(2, 100), excerpt(3, 100)], [excerpt(4, 100), excerpt(5, 100), excerpt(6, 100)]]
        let picked = SolveContext.pick(lists, already: [], budget: 400)
        #expect(picked.map(\.itemId) == [1, 2, 4, 5])
        #expect(picked.map(\.number) == [1, 2, 3, 4])
        #expect(picked.reduce(0) { $0 + $1.text.count } <= 400)
        // A follow-up's budget is what is left; numbers continue.
        let more = SolveContext.pick(lists, already: Set(picked.map { "\($0.itemId):\($0.page)" }), budget: 100)
        #expect(more.map(\.itemId) == [3] && more.map(\.number) == [5])
        #expect(SolveContext.excerptBudget == 50_000)
    }
}
