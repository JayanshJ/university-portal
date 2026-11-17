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
        /// Indexing the course PDFs and digesting new ones into the course memory.
        case memory(CourseMemory.Progress)
        /// Reading the sheet's submission rules.
        case rules
        /// The rules ask for details the student hasn't given yet; waits for `saveDetails`.
        case needsDetails([SubmissionRules.Field])
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

    var isBusy: Bool {
        switch phase {
        case .reading, .memory, .rules, .writing: true
        case .idle, .needsDetails, .failed: false
        }
    }
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

    let assignment: AssignmentRules
    /// The sheet's submission rules (header fields, file name), once read.
    private(set) var rules: SubmissionRules?
    /// Course PDFs Solve cannot read, with the reason.
    private(set) var unread: [(title: String, reason: String)] = []
    /// What the current solution drew on, from the finished reply.
    private(set) var sources: [SolveReply.Source] = []
    /// Every excerpt sent to the model so far, numbered in order.
    private(set) var excerpts: [Excerpt] = []
    private(set) var student: StudentDetails
    private(set) var courseDetails: CourseDetails
    /// Header values typed for this PDF only.
    private(set) var headerOverrides: [SubmissionRules.Field: String] = [:]
    /// The deadline's course first, then related courses (its CMS page); empty without a deadline.
    let courseIds: [Int64]
    let courseName: String
    let courseShort: String
    /// The sheet number from the assignment's name, when it names exactly one.
    let sheetNumber: Int?
    /// Course PDFs that could be the sheet, best match first.
    let candidates: [SheetFinder.Candidate]
    private(set) var sheet: Sheet
    /// The user picked the sheet (or chose none), so Solve doesn't ask again.
    private var sheetChosen = false
    @ObservationIgnored private let service: MoodleSubmissions
    @ObservationIgnored private let database: UniDatabase
    @ObservationIgnored private let ask: AskModel
    @ObservationIgnored private let deadline: PortalOverview.ItemRow?
    @ObservationIgnored private let openMaterial: (PortalOverview.ItemRow) async throws -> URL
    @ObservationIgnored private var task: (text: String, images: [Data])?
    /// Set when ChatGPT refused the page images; later requests send text only.
    @ObservationIgnored private var imagesRefused = false
    @ObservationIgnored private var replying: Task<Void, Never>?
    @ObservationIgnored private var converting: Task<Void, Never>?
    /// Memory, rules and details before the first reply.
    @ObservationIgnored private var preparing: Task<Void, Never>?
    /// The memory build, cancelled on its own by Skip for Now.
    @ObservationIgnored private var memoryBuild: Task<CourseMemory.Progress, Never>?
    /// Ends the wait for indexing (indexing finished, or Skip for Now).
    @ObservationIgnored private var memoryGate: AsyncStream<Void>.Continuation?
    /// Bumped after each memory build, so late progress updates of a finished build are dropped.
    @ObservationIgnored private var memoryRun = 0
    /// The memory was built (or skipped) for this panel; `retryMemory` builds it again.
    @ObservationIgnored private var memoryReady = false
    /// The course memory as sent to the model, made once per solve.
    @ObservationIgnored private var memoryText: String?
    /// The sheet file's own text, and its material id when it is a course PDF.
    @ObservationIgnored private var sheetText = ""
    @ObservationIgnored private var sheetItemId: Int64?

    init(assignment: AssignmentRules, service: MoodleSubmissions, ask: AskModel, database: UniDatabase,
         deadline: PortalOverview.ItemRow?, courseIds: [Int64], courseName: String, courseShort: String,
         candidates: [SheetFinder.Candidate], openMaterial: @escaping (PortalOverview.ItemRow) async throws -> URL) {
        self.assignment = assignment
        self.service = service
        self.ask = ask
        self.database = database
        self.courseIds = courseIds
        self.courseName = courseName
        self.courseShort = courseShort
        let numbers = SheetFinder.sheetNumbers(in: assignment.name)
        sheetNumber = numbers.count == 1 ? numbers.first : nil
        student = StudentDetails.load(database)
        courseDetails = courseIds.first.map { CourseDetails.load(database, courseId: $0) } ?? CourseDetails()
        self.deadline = deadline
        self.candidates = candidates
        self.openMaterial = openMaterial
        sheet = SheetFinder.best(candidates).map(Sheet.material) ?? .none
        format = Format(rawValue: UserDefaults.standard.string(forKey: "solveFormat") ?? "") ?? .typed
    }

    var signedIn: Bool { ask.account?.canUsePlan == true && ask.model != nil }

    /// Nothing to solve from yet: no sheet found, no attachment and hardly any description.
    var needsSheet: Bool {
        !sheetChosen && sheet == .none && assignment.attachments.isEmpty
            && (assignment.intro + (deadline?.body ?? "")).trimmingCharacters(in: .whitespacesAndNewlines).count < 300
    }

    // MARK: - Solving and editing

    func start() {
        guard messages.isEmpty, signedIn, !needsSheet, !isBusy, preparing == nil else { return }
        if case .needsDetails = phase { return }
        prepare()
    }

    /// Uses another sheet (or none) and solves again; its rules are read again.
    func choose(_ sheet: Sheet) {
        replying?.cancel()
        preparing?.cancel()
        self.sheet = sheet
        sheetChosen = true
        task = nil
        sheetText = ""
        sheetItemId = nil
        rules = nil
        if case .needsDetails = phase { phase = .idle }
        Task {
            await replying?.value
            await preparing?.value
            resolve()
        }
    }

    func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isBusy, signedIn else { return }
        if case .needsDetails = phase { return }
        messages.append(Message(role: .user, text: text))
        reply(to: text)
    }

    func stop() {
        replying?.cancel()
        preparing?.cancel()
    }

    /// Starts over: a fresh solution from the task.
    func resolve() {
        guard !isBusy, preparing == nil else { return }
        messages = []
        solution = ""
        revision = 0
        handwriting = .none
        sources = []
        excerpts = []
        memoryText = nil
        if rules == nil || !memoryReady {
            prepare()
        } else {
            phase = .idle
            reply(to: nil)
        }
    }

    // MARK: - Memory, rules and details

    /// Before the first reply: the course memory, the files it can't read, the sheet's submission
    /// rules, and the student's details those rules need.
    private func prepare() {
        preparing = Task {
            defer { preparing = nil }
            do {
                if !memoryReady { await buildMemory() }
                try Task.checkCancellation()
                if rules == nil {
                    let task = try await readTask()
                    rules = try await readRules(task)
                }
                try Task.checkCancellation()
                let missing = missingDetails()
                if !missing.isEmpty {
                    phase = .needsDetails(missing)
                    return
                }
                phase = .idle
                reply(to: nil)
            } catch {
                let stopped = error is CancellationError || Task.isCancelled
                phase = .failed(stopped ? "Stopped." : AskModel.describe(error))
                if case ChatGPTError.signInExpired = error { await ask.refreshAccount() }
            }
        }
    }

    /// Indexes the courses' PDFs, then digests new ones. Skip for Now stops waiting for indexing
    /// (it finishes in the background) or cancels the build; either way Solve goes on with what exists.
    private func buildMemory() async {
        memoryReady = true
        memoryText = nil
        guard let memoryCourseId = courseIds.first, let memory = ask.memory() else { return }
        let ids = courseIds
        let run = memoryRun
        phase = .memory(CourseMemory.Progress())

        let (gate, continuation) = AsyncStream<Void>.makeStream()
        memoryGate = continuation
        let ask = ask
        Task {
            _ = await ask.indexCourses(ids)
            continuation.yield()
        }
        var skipped = true
        for await _ in gate {
            skipped = memoryGate == nil
            break
        }
        memoryGate = nil

        if !skipped, !Task.isCancelled {
            let report: @Sendable (CourseMemory.Progress) -> Void = { [weak self] progress in
                Task { @MainActor in
                    guard let self, self.memoryRun == run, case .memory = self.phase else { return }
                    self.phase = .memory(progress)
                }
            }
            let build = Task { await memory.run(courseIds: ids, memoryCourseId: memoryCourseId, onProgress: report) }
            memoryBuild = build
            _ = await withTaskCancellationHandler { await build.value } onCancel: { build.cancel() }
            memoryBuild = nil
        }
        memoryRun += 1
        unread = (try? memory.unread(courseIds: ids)) ?? []
    }

    /// Stops the memory step and solves with what the memory has so far.
    func skipMemory() {
        guard case .memory = phase else { return }
        if let memoryGate {
            self.memoryGate = nil
            memoryGate.yield()
        }
        memoryBuild?.cancel()
    }

    /// Builds the memory again (files that failed are read again). Before the first reply this
    /// continues to the solution; afterwards the next reply uses the new memory.
    func retryMemory() {
        guard !isBusy, preparing == nil else { return }
        memoryReady = false
        if messages.isEmpty {
            prepare()
            return
        }
        preparing = Task {
            defer { preparing = nil }
            await buildMemory()
            phase = .idle
        }
    }

    /// One call: the sheet's header fields, file name pattern and other submission rules. Falls back
    /// to `.none` when ChatGPT fails.
    private func readRules(_ task: (text: String, images: [Data])) async throws -> SubmissionRules {
        guard let model = ask.model else { return .none }
        phase = .rules
        var parts = ["# Assignment: \(assignment.name)"]
        if !assignment.intro.isEmpty { parts.append(assignment.intro) }
        parts.append("## Sheet\n\n" + String((sheetText.isEmpty ? task.text : sheetText).prefix(60_000)))
        if let sheetItemId, let digest = memoryDocument()?.files.first(where: { $0.itemId == sheetItemId })?.digest {
            parts.append("## Digest of the sheet\n\n" + digest)
        }
        do {
            let reply = try await ask.client.complete(model: model, instructions: SubmissionRules.instructions,
                                                      input: [ChatMessage(role: .user, content: parts.joined(separator: "\n\n"))])
            return SubmissionRules.parse(reply)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            return .none
        }
    }

    private func memoryDocument() -> MemoryDocument? {
        guard let memoryCourseId = courseIds.first, let memory = ask.memory() else { return nil }
        return try? memory.document(memoryCourseId: memoryCourseId, courseIds: courseIds)
    }

    /// Fields the rules need that are still empty and not typed in for this PDF.
    private func missingDetails() -> [SubmissionRules.Field] {
        (rules ?? .none).missing(student: student, course: courseDetails, sheet: sheetNumber).filter {
            (headerOverrides[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Saves the student's and the course's details and, when Solve was waiting for them, solves.
    func saveDetails(student: StudentDetails, course: CourseDetails) {
        try? student.save(database)
        if let courseId = courseIds.first { try? course.save(database, courseId: courseId) }
        self.student = student
        courseDetails = course
        guard case .needsDetails = phase else { return }
        phase = .idle
        reply(to: nil)
    }

    /// A header value for this PDF only (not saved).
    func overrideHeader(_ field: SubmissionRules.Field, value: String) {
        headerOverrides[field] = value
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
                let context = courseContext(for: request, task: task.text)
                let instructions = context == nil ? Self.instructions : Self.instructions + "\n\n" + Self.memoryInstructions
                phase = .writing
                let first = context.map { $0 + "\n\n" + task.text } ?? task.text
                var input = [ChatMessage(role: .user, content: first, images: imagesRefused ? [] : task.images)]
                if let request {
                    input.append(ChatMessage(role: .assistant, content: "<solution>\n\(previous)\n</solution>"))
                    for message in history where !message.failed && !message.text.isEmpty {
                        input.append(ChatMessage(role: message.role == .user ? .user : .assistant, content: message.text))
                    }
                    input.append(ChatMessage(role: .user, content: request))
                }
                var raw = ""
                do {
                    for try await delta in ask.client.stream(model: model, instructions: instructions, input: input) {
                        raw += delta
                        let parsed = SolveReply.parse(raw)
                        messages[index].text = parsed.note
                        if let draft = parsed.solution { solution = draft }
                    }
                } catch ChatGPTError.server where raw.isEmpty && !input[0].images.isEmpty {
                    // The model or plan doesn't take images: ask again with the sheet's text only.
                    imagesRefused = true
                    input[0].images = []
                    for try await delta in ask.client.stream(model: model, instructions: instructions, input: input) {
                        raw += delta
                        let parsed = SolveReply.parse(raw)
                        messages[index].text = parsed.note
                        if let draft = parsed.solution { solution = draft }
                    }
                }
                let parsed = SolveReply.parse(raw)
                // Without a <solution> tag a first reply is all solution; the note never holds <sources>.
                if let final = parsed.solution ?? (request == nil ? parsed.note : nil), !final.isEmpty {
                    solution = final.trimmingCharacters(in: .whitespacesAndNewlines)
                    sources = parsed.sources
                    revision += 1
                    if parsed.solution == nil { messages[index].text = "" }
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
        var parts = ["# Assignment: \(assignment.name)"]
        if let course = deadline?.courseFullName { parts.append("Course: \(course)") }
        if !assignment.intro.isEmpty { parts.append(assignment.intro) }
        if let body = deadline?.body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty, !assignment.intro.contains(body) {
            parts.append(body)
        }
        var images: [Data] = []
        /// Adds the file and returns its text.
        @discardableResult func add(_ filename: String, _ data: Data) -> String {
            if let pdf = PDFDocument(data: data) {
                let pages = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }
                let text = pages.enumerated().map { "[Page \($0.offset + 1)]\n\($0.element)" }.joined(separator: "\n\n")
                parts.append("## File: \(filename)\n\n" + text)
                for index in 0..<pdf.pageCount where images.count < Self.maxImages {
                    if let page = pdf.page(at: index), let jpeg = Self.jpeg(page) { images.append(jpeg) }
                }
                return text
            } else if let text = String(data: data, encoding: .utf8), data.count < 200_000 {
                parts.append("## File: \(filename)\n\n\(text)")
                return text
            } else {
                parts.append("## File: \(filename) (not readable as text)")
                return ""
            }
        }

        switch sheet {
        case .none:
            sheetText = ""
            sheetItemId = nil
        case .material(let candidate):
            phase = .reading("Reading \(candidate.name)…")
            let url = try await openMaterial(candidate.item)
            sheetText = add(candidate.item.filename ?? candidate.name, try Data(contentsOf: url))
            sheetItemId = candidate.item.id
        case .file(let name, let data):
            sheetText = add(name, data)
            sheetItemId = nil
        }
        for (number, file) in assignment.attachments.enumerated() {
            phase = .reading("Reading \(file.filename) (\(number + 1) of \(assignment.attachments.count))…")
            add(file.filename, try await service.download(file).data)
        }
        if !images.isEmpty { parts.append("The pages of the files above are attached as images; where the extracted text is garbled, the images are right.") }
        let task = (parts.joined(separator: "\n\n"), images)
        self.task = task
        return task
    }

    static let maxImages = 10

    /// The course memory and the numbered excerpts, put before the task. The first reply retrieves
    /// excerpts for each task on the sheet; a follow-up adds excerpts for the request that weren't
    /// sent yet, numbered after the earlier ones.
    private func courseContext(for request: String?, task: String) -> String? {
        guard !courseIds.isEmpty else { return nil }
        let retriever = Retriever(database: database)
        if request != nil || excerpts.isEmpty {
            let queries = request.map { [$0] } ?? SolveContext.tasks(in: sheetText.isEmpty ? task : sheetText)
            let already = Set(excerpts.map { "\($0.itemId):\($0.page)" })
            if let new = try? SolveContext.excerpts(retriever: retriever, tasks: queries, courseIds: courseIds, already: already) {
                excerpts += new
            }
        }
        if memoryText == nil, let document = memoryDocument() {
            var text = CourseMemory.text(document, keeping: [sheetItemId].compactMap { $0 } + excerpts.map(\.itemId))
            if !unread.isEmpty {
                text += "\n\n## Not read\n" + unread.map { "- \($0.title) — \($0.reason)" }.joined(separator: "\n")
            }
            memoryText = text
        }
        var parts: [String] = []
        if let memoryText { parts.append("# Course memory\n\n" + memoryText) }
        if !excerpts.isEmpty {
            parts.append("# Excerpts from the course materials\n\n" + excerpts.map {
                "[\($0.number)] \($0.course) — \($0.title), page \($0.page)\n\($0.text)"
            }.joined(separator: "\n\n"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

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

    static let memoryInstructions = """
        Before the assignment, the first user message holds the course memory (the student's notes, \
        a course overview and a digest of each course file, each under a "## " heading) and numbered \
        excerpts from the course materials ([1], [2], …). Solve \
        the way this course does: use its notation, definitions, theorems and methods, and name a \
        result from the lecture the way the lecture does. Never mention the memory, the excerpts or \
        their numbers inside the solution.

        After </solution>, end the reply with a block listing what you used, one per line: an excerpt \
        number in square brackets, or "memory: " and the heading of a memory section. For example:
        <sources>
        [2]
        memory: Course overview
        </sources>
        Leave it out when you used none of them.
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
        rules = SubmissionRules.none
        memoryReady = true
        revision = 2
        phase = .idle
        if let rendering { handwriting = .ready(rendering, revision: revision) }
    }

    // MARK: - Output

    var suggestedFilename: String {
        let base = assignment.name.replacingOccurrences(of: #"[/\\:*?"<>|]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return "\(base.isEmpty ? "Solution" : base) - Solution.pdf"
    }

    /// The solution as a PDF in the chosen format.
    func pdf() async throws -> Data {
        switch format {
        case .typed:
            return try await SolutionPDF.make(markdown: solution, title: assignment.name)
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
