import Foundation

/// "Ask your materials": widen the question into English and German search terms, retrieve page
/// excerpts, and stream an answer that cites them by number.
public struct AskService: Sendable {
    let retriever: Retriever
    let client: ResponsesClient

    public init(retriever: Retriever, client: ResponsesClient) {
        self.retriever = retriever
        self.client = client
    }

    /// The excerpts for a question. `history` lets a follow-up ("and in sheet 2?") inherit its topic.
    public func excerpts(for question: String, history: [ChatMessage], courseId: Int64?, model: String) async throws -> [Excerpt] {
        let terms = await expandedTerms(question: question, history: history, model: model)
        let context = history.last { $0.role == .user }?.content ?? ""
        let found = try retriever.excerpts(for: question, extraTerms: terms, courseId: courseId)
        if found.isEmpty, !context.isEmpty {
            return try retriever.excerpts(for: question + " " + context, extraTerms: terms, courseId: courseId)
        }
        return found
    }

    /// Search terms from the model; on any failure the search falls back to the question's own words.
    func expandedTerms(question: String, history: [ChatMessage], model: String) async -> [String] {
        let recent = history.suffix(2).map { "\($0.role == .user ? "Student" : "Assistant"): \($0.content.prefix(400))" }
        let prompt = (recent.isEmpty ? "" : "Conversation so far:\n" + recent.joined(separator: "\n") + "\n\n")
            + "Question: \(question)"
        guard let line = try? await client.complete(model: model, instructions: Self.expansionInstructions,
                                                    input: [ChatMessage(role: .user, content: prompt)]) else { return [] }
        return line.split(whereSeparator: { ",;\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'*-•"))) }
            .filter { !$0.isEmpty && $0.count <= 60 }
            .prefix(20).map { $0 }
    }

    /// Streams the answer for `question` grounded in `excerpts`.
    public func answer(question: String, excerpts: [Excerpt], history: [ChatMessage], model: String) -> AsyncThrowingStream<String, Error> {
        let input = Array(history.suffix(6)) + [ChatMessage(role: .user, content: Self.prompt(question: question, excerpts: excerpts))]
        return client.stream(model: model, instructions: Self.answerInstructions, input: input)
    }

    static func prompt(question: String, excerpts: [Excerpt]) -> String {
        guard !excerpts.isEmpty else {
            return "No excerpts from my course materials matched this question.\n\nQuestion: \(question)"
        }
        let blocks = excerpts.map { excerpt in
            "[\(excerpt.number)] \(excerpt.course) — \(excerpt.title), page \(excerpt.page)\n\(excerpt.text)"
        }
        return "Excerpts from my course materials:\n\n" + blocks.joined(separator: "\n\n") + "\n\nQuestion: \(question)"
    }

    /// Citation numbers in an answer: "[2]", "[1][3]", "[1, 3]".
    public static func citations(in text: String) -> [Int] {
        let pattern = try! NSRegularExpression(pattern: #"\[(\d+(?:\s*,\s*\d+)*)\]"#)
        var numbers: [Int] = []
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            for part in text[range].split(separator: ",") {
                if let number = Int(part.trimmingCharacters(in: .whitespaces)), !numbers.contains(number) {
                    numbers.append(number)
                }
            }
        }
        return numbers
    }

    static let expansionInstructions = """
        You turn a student's question into search keywords for a full-text search over their lecture slides, \
        scripts and exercise sheets, which may be written in English or German. Reply with ONE line only: \
        6 to 15 keywords or short phrases separated by commas. Include the key terms in both English and German, \
        common synonyms and abbreviations, and the names of specific sheets or lectures if mentioned. \
        No explanations, no numbering.
        """

    static let answerInstructions = """
        You are the study assistant in University Portal. You answer a university student's questions using \
        numbered excerpts from their own course materials (lecture slides, scripts, exercise sheets), each \
        labelled with its course, file and page.

        Rules:
        - Ground the answer in the excerpts. Cite them inline with their numbers in square brackets right after \
        the sentence they support, e.g. [2] or [1][3]. Only cite numbers that exist.
        - If the excerpts don't contain the answer, say so first ("I couldn't find this in your materials."). You may \
        then add a short explanation labelled "General knowledge:" without citations.
        - Answer in the language of the question, even when the materials are in another language.
        - Be concise and structured: short paragraphs or bullet points, key terms in bold. Write formulas in plain \
        text (no LaTeX).
        - For exercise sheets, explain the concepts and give hints; don't write complete solutions to graded tasks.
        - Never invent page numbers, file names or facts that are not in the excerpts.
        """
}
