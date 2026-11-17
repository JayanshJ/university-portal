import AppKit
import Foundation
import PDFKit
import UniversityKit

/// The Solve panel next to an assignment's hand-in sheet: ChatGPT (the Codex models on the user's
/// plan, through Ask's sign-in) writes a solution, the user reviews it and asks for changes in a
/// chat, and the result goes into the submission as a typed PDF or, once they've set up their
/// handwriting (Settings → Handwriting), as a PDF in their own handwriting.
@MainActor @Observable
final class SolveModel {
    enum Format: String, CaseIterable, Identifiable {
        case handwritten, typed
        var id: String { rawValue }
        var title: String { self == .handwritten ? "Handwritten" : "Typed" }
    }

    struct Message: Identifiable, Equatable {
        enum Role { case user, assistant }
        let id = UUID()
        var role: Role
        var text: String
        var failed = false
    }

    enum Phase: Equatable {
        case idle
        case reading(String)
        case writing
        case failed(String)
    }

    enum Handwriting: Equatable {
        case none
        case converting
        case rendering
        case ready(Handwriter.Rendering, revision: Int)
        case failed(String)
        case notSetUp
    }

    private(set) var messages: [Message] = []
    /// The current solution (Markdown with LaTeX); while a reply streams, the draft in progress.
    private(set) var solution = ""
    /// Bumped each time a reply finishes with a new solution.
    private(set) var revision = 0
    private(set) var phase: Phase = .idle
    private(set) var handwriting: Handwriting = .none
    var format: Format {
        didSet {
            UserDefaults.standard.set(format.rawValue, forKey: "solveFormat")
            if format == .handwritten { renderHandwritingIfNeeded() }
        }
    }

    var isBusy: Bool { phase == .writing || { if case .reading = phase { true } else { false } }() }
    var hasSolution: Bool { revision > 0 }

    /// The exercise sheet Solve works from, besides the assignment's own description and attachments.
    enum Sheet: Equatable {
        case none
        case material(SheetFinder.Candidate)
        case file(name: String, data: Data)

        var name: String? {
            switch self {
            case .none: nil
            case .material(let candidate): candidate.name
            case .file(let name, _): name
            }
        }
    }

    let rules: AssignmentRules
    /// Course PDFs that could be the sheet, best match first.
    let candidates: [SheetFinder.Candidate]
    private(set) var sheet: Sheet
    /// The user picked the sheet (or chose none), so Solve doesn't ask again.
    private var sheetChosen = false
    @ObservationIgnored private let service: MoodleSubmissions
    @ObservationIgnored private let ask: AskModel
    @ObservationIgnored private let deadline: PortalOverview.ItemRow?
    @ObservationIgnored private let openMaterial: (PortalOverview.ItemRow) async throws -> URL
    @ObservationIgnored private var task: (text: String, images: [Data])?
    /// Set when ChatGPT refused the page images; later requests send text only.
    @ObservationIgnored private var imagesRefused = false
    @ObservationIgnored private var replying: Task<Void, Never>?
    @ObservationIgnored private var converting: Task<Void, Never>?

    init(rules: AssignmentRules, service: MoodleSubmissions, ask: AskModel, deadline: PortalOverview.ItemRow?,
         candidates: [SheetFinder.Candidate], openMaterial: @escaping (PortalOverview.ItemRow) async throws -> URL) {
        self.rules = rules
        self.service = service
        self.ask = ask
        self.deadline = deadline
        self.candidates = candidates
        self.openMaterial = openMaterial
        sheet = SheetFinder.best(candidates).map(Sheet.material) ?? .none
        format = Format(rawValue: UserDefaults.standard.string(forKey: "solveFormat") ?? "") ?? .typed
    }

    var signedIn: Bool { ask.account?.canUsePlan == true && ask.model != nil }

    /// Nothing to solve from yet: no sheet found, no attachment and hardly any description.
    var needsSheet: Bool {
        !sheetChosen && sheet == .none && rules.attachments.isEmpty
            && (rules.intro + (deadline?.body ?? "")).trimmingCharacters(in: .whitespacesAndNewlines).count < 300
    }

    // MARK: - Solving and editing

    func start() {
        guard messages.isEmpty, signedIn, !needsSheet, !isBusy else { return }
        reply(to: nil)
    }

    /// Uses another sheet (or none) and solves again.
    func choose(_ sheet: Sheet) {
        replying?.cancel()
        self.sheet = sheet
        sheetChosen = true
        task = nil
        Task {
            await replying?.value
            resolve()
        }
    }

    func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isBusy, signedIn else { return }
        messages.append(Message(role: .user, text: text))
        reply(to: text)
    }

    func stop() { replying?.cancel() }

    /// Starts over: a fresh solution from the task.
    func resolve() {
        guard !isBusy else { return }
        messages = []
        solution = ""
        revision = 0
        handwriting = .none
        reply(to: nil)
    }

    private func reply(to request: String?) {
        guard let model = ask.model else { return }
        let previous = solution
        let history = messages.dropLast(request == nil ? 0 : 1).suffix(8)
        messages.append(Message(role: .assistant, text: ""))
        let index = messages.count - 1

        replying = Task {
            do {
                let task = try await readTask()
                phase = .writing
                var input = [ChatMessage(role: .user, content: task.text, images: imagesRefused ? [] : task.images)]
                if let request {
                    input.append(ChatMessage(role: .assistant, content: "<solution>\n\(previous)\n</solution>"))
                    for message in history where !message.failed && !message.text.isEmpty {
                        input.append(ChatMessage(role: message.role == .user ? .user : .assistant, content: message.text))
                    }
                    input.append(ChatMessage(role: .user, content: request))
                }
                var raw = ""
                do {
                    for try await delta in ask.client.stream(model: model, instructions: Self.instructions, input: input) {
                        raw += delta
                        let parsed = SolveReply.parse(raw)
                        messages[index].text = parsed.note
                        if let draft = parsed.solution { solution = draft }
                    }
                } catch ChatGPTError.server where raw.isEmpty && !input[0].images.isEmpty {
                    // The model or plan doesn't take images: ask again with the sheet's text only.
                    imagesRefused = true
                    input[0].images = []
                    for try await delta in ask.client.stream(model: model, instructions: Self.instructions, input: input) {
                        raw += delta
                        let parsed = SolveReply.parse(raw)
                        messages[index].text = parsed.note
                        if let draft = parsed.solution { solution = draft }
                    }
                }
                let parsed = SolveReply.parse(raw)
                if let final = parsed.solution ?? (request == nil ? raw : nil), !final.isEmpty {
                    solution = final.trimmingCharacters(in: .whitespacesAndNewlines)
                    revision += 1
                    if messages[index].text.isEmpty { messages[index].text = request == nil ? "Here's a full solution." : "Updated." }
                } else {
                    solution = previous
                }
                phase = .idle
                if format == .handwritten { renderHandwritingIfNeeded() }
            } catch {
                solution = previous
                let stopped = error is CancellationError
                messages[index].text = stopped ? (messages[index].text.isEmpty ? "Stopped." : messages[index].text) : AskModel.describe(error)
                messages[index].failed = !stopped
                phase = stopped ? .idle : .failed(AskModel.describe(error))
                if case ChatGPTError.signInExpired = error { await ask.refreshAccount() }
            }
        }
    }

    /// The assignment: its name and description, the text of its attachments and of the sheet, and
    /// the PDF pages as images (formulas rarely survive text extraction).
    private func readTask() async throws -> (text: String, images: [Data]) {
        if let task { return task }
        var parts = ["# Assignment: \(rules.name)"]
        if let course = deadline?.courseFullName { parts.append("Course: \(course)") }
        if !rules.intro.isEmpty { parts.append(rules.intro) }
        if let body = deadline?.body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty, !rules.intro.contains(body) {
            parts.append(body)
        }
        var images: [Data] = []
        func add(_ filename: String, _ data: Data) {
            if let pdf = PDFDocument(data: data) {
                let pages = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }
                parts.append("## File: \(filename)\n\n" + pages.enumerated().map { "[Page \($0.offset + 1)]\n\($0.element)" }.joined(separator: "\n\n"))
                for index in 0..<pdf.pageCount where images.count < Self.maxImages {
                    if let page = pdf.page(at: index), let jpeg = Self.jpeg(page) { images.append(jpeg) }
                }
            } else if let text = String(data: data, encoding: .utf8), data.count < 200_000 {
                parts.append("## File: \(filename)\n\n\(text)")
            } else {
                parts.append("## File: \(filename) (not readable as text)")
            }
        }

        switch sheet {
        case .none: break
        case .material(let candidate):
            phase = .reading("Reading \(candidate.name)…")
            let url = try await openMaterial(candidate.item)
            add(candidate.item.filename ?? candidate.name, try Data(contentsOf: url))
        case .file(let name, let data):
            add(name, data)
        }
        for (number, file) in rules.attachments.enumerated() {
            phase = .reading("Reading \(file.filename) (\(number + 1) of \(rules.attachments.count))…")
            add(file.filename, try await service.download(file).data)
        }
        if !images.isEmpty { parts.append("The pages of the files above are attached as images; where the extracted text is garbled, the images are right.") }
        let task = (parts.joined(separator: "\n\n"), images)
        self.task = task
        return task
    }

    static let maxImages = 10

    /// A PDF page as a JPEG about 1400 pixels wide.
    static func jpeg(_ page: PDFPage) -> Data? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0 else { return nil }
        let scale = 1400 / bounds.width
        let image = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }

    static let instructions = """
        You solve university assignments (exercise sheets) for a student, who reviews your solution \
        and hands it in. The first user message is the assignment: its description, the text \
        extracted from the exercise sheet (formulas may be garbled), and usually the sheet's pages as \
        images. Solve exactly the tasks on that sheet. Never ask the student to send the assignment; \
        if something is unreadable or missing, solve what is there and say in your note what you assumed.

        Write the solution the way a strong student hands it in: every task and subtask in order, \
        each with a heading (e.g. "## Aufgabe 1", then "(a)", "(b)"), the essential steps and \
        reasoning, and the final result of each part in \\boxed{...}. Write in the language of the \
        assignment. Use Markdown with LaTeX math ($...$ inline, $$...$$ display). No tables of \
        contents, no remarks about being an AI, no meta-commentary inside the solution.

        Reply format, always: first one short sentence to the student (what you did or changed), \
        then the complete solution document between <solution> and </solution> on their own lines.

        Later messages are the student's review: apply each requested change and return the full, \
        revised solution in the same format, keeping everything they didn't ask to change. If a \
        message is only a question, answer it in a few sentences and omit the <solution> block.
        """

    // MARK: - Handwriting (Math Writer)

    /// After the student set up their handwriting from the panel.
    func handwritingChanged() {
        handwriting = .none
        renderHandwritingIfNeeded()
    }

    func renderHandwritingIfNeeded() {
        guard hasSolution, !isBusy, converting == nil else { return }
        if case .ready(_, let rendered) = handwriting, rendered == revision { return }
        guard Handwriter.isSetUp else {
            handwriting = .notSetUp
            return
        }
        let target = revision
        let solution = solution
        converting = Task {
            do {
                handwriting = .converting
                var markup = try await convert(solution, fixing: nil)
                handwriting = .rendering
                let rendering: Handwriter.Rendering
                do {
                    rendering = try await Handwriter.render(markup, strict: true)
                } catch Handwriter.Failure.invalidMarkup(let errors) {
                    // One repair round with the validator's errors, then render whatever is left.
                    handwriting = .converting
                    markup = try await convert(markup, fixing: errors)
                    handwriting = .rendering
                    rendering = try await Handwriter.render(markup, strict: false)
                }
                handwriting = .ready(rendering, revision: target)
            } catch Handwriter.Failure.notSetUp {
                handwriting = .notSetUp
            } catch let failure as Handwriter.Failure {
                handwriting = .failed(failure.errorDescription ?? "Math Writer failed.")
            } catch {
                handwriting = .failed(AskModel.describe(error))
            }
            converting = nil
            // The solution changed while this one rendered: render the new one.
            if target != revision { renderHandwritingIfNeeded() }
        }
    }

    /// Markdown + LaTeX → Math Writer markup, or a repair of markup the validator rejected.
    private func convert(_ text: String, fixing errors: [String]?) async throws -> String {
        guard let model = ask.model else { throw ChatGPTError.notSignedIn }
        let request = if let errors {
            "This Math Writer markup fails validation. Fix exactly these problems and return the full corrected markup:\n"
                + errors.map { "- \($0)" }.joined(separator: "\n") + "\n\n" + text
        } else {
            "Convert this solution:\n\n" + text
        }
        var markup = try await ask.client.complete(model: model, instructions: Self.markupInstructions,
                                                   input: [ChatMessage(role: .user, content: request)])
        markup = markup.trimmingCharacters(in: .whitespacesAndNewlines)
        if markup.hasPrefix("```") {  // a fenced reply despite the instructions
            markup = markup.split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
                .joined(separator: "\n").replacingOccurrences(of: #"\n?```\s*$"#, with: "", options: .regularExpression)
        }
        return markup
    }

    static var markupInstructions: String {
        """
        You convert a math solution written in Markdown + LaTeX into the plain-text markup of Math \
        Writer, a renderer that writes it in the student's own handwriting. Keep the content and \
        language exactly; only change the notation. Output only the markup: no code fences, no \
        comments. Headings ("## Aufgabe 1") become ~~Aufgabe 1~~ on their own line. Bold/italic \
        become plain text. \\boxed{...} becomes [B]...[/B]. Use Unicode sub/superscripts where \
        they exist, and the tags otherwise. Avoid characters the renderer has no glyph for \
        (emoji, % # & @ \\, rare symbols): write them out in words. Keep lines reasonably short: \
        one equation or sentence per line, a blank line between paragraphs.

        The student's handwriting has only these characters (plus spaces, the tags, Unicode \
        sub/superscripts and the procedural → ≈ ∫ ✓); rewrite anything else in words or with these: \
        \(Handwriter.characters)

        The markup reference:

        \(Handwriter.markupGuide)
        """
    }

    /// Debug screenshots (--solve-check): a finished solution without calling ChatGPT.
    func showDemo(request: String, note: String, solution: String, rendering: Handwriter.Rendering?) {
        messages = [Message(role: .assistant, text: "Here's a full solution."), Message(role: .user, text: request),
                    Message(role: .assistant, text: note)]
        self.solution = solution
        sheetChosen = true
        revision = 2
        phase = .idle
        if let rendering { handwriting = .ready(rendering, revision: revision) }
    }

    // MARK: - Output

    var suggestedFilename: String {
        let base = rules.name.replacingOccurrences(of: #"[/\\:*?"<>|]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return "\(base.isEmpty ? "Solution" : base) - Solution.pdf"
    }

    /// The solution as a PDF in the chosen format.
    func pdf() async throws -> Data {
        switch format {
        case .typed:
            return try await SolutionPDF.make(markdown: solution, title: rules.name)
        case .handwritten:
            guard case .ready(let rendering, let rendered) = handwriting, rendered == revision else {
                throw Handwriter.Failure.failed("The handwritten version isn't ready yet.")
            }
            return try Data(contentsOf: rendering.pdf)
        }
    }

    var canExport: Bool {
        guard hasSolution, !isBusy else { return false }
        if format == .handwritten, case .ready(_, let rendered) = handwriting { return rendered == revision }
        return format == .typed
    }

    /// Opens the PDF in the default viewer (Preview).
    func openPDF() async throws {
        let data = try await pdf()
        let url = FileManager.default.temporaryDirectory.appending(path: suggestedFilename)
        try data.write(to: url)
        NSWorkspace.shared.open(url)
    }
}
