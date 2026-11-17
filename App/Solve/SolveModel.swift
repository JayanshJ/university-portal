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
    var phase: Phase = .idle
    private(set) var handwriting: Handwriting = .none
    var format: Format {
        didSet {
            UserDefaults.standard.set(format.rawValue, forKey: "solveFormat")
            // The error was the other format's: this one gets its own try.
            outputError = nil
            if format == .handwritten { renderHandwritingIfNeeded() }
            makePreview()
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
    /// The sheet's submission rules (header fields, file name), once read. Nil while unknown,
    /// including after a failed rules call (see `rulesError`).
    var rules: SubmissionRules?
    /// Why the rules call failed; Solve waits until it is retried or the student continues
    /// without rules.
    var rulesError: String?
    /// Fields the student marked "Not needed for this sheet" for this PDF (not saved).
    private(set) var droppedFields: Set<SubmissionRules.Field> = []
    /// Course PDFs Solve cannot read, with the reason.
    var unread: [(title: String, reason: String)] = []
    /// What the current solution drew on, from the finished reply.
    private(set) var sources: [SolveReply.Source] = []
    /// Every excerpt sent to the model so far, numbered in order.
    private(set) var excerpts: [Excerpt] = []
    var student: StudentDetails
    var courseDetails: CourseDetails
    /// Header values typed for this PDF only.
    var headerOverrides: [SubmissionRules.Field: String] = [:]
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
    @ObservationIgnored let database: UniDatabase
    @ObservationIgnored let ask: AskModel
    @ObservationIgnored private let deadline: PortalOverview.ItemRow?
    @ObservationIgnored private let openMaterial: (PortalOverview.ItemRow) async throws -> URL
    @ObservationIgnored private var task: (text: String, images: [Data])?
    /// Set when ChatGPT refused the page images; later requests send text only.
    @ObservationIgnored private var imagesRefused = false
    @ObservationIgnored private var replying: Task<Void, Never>?
    @ObservationIgnored private var converting: Task<Void, Never>?
    /// Memory, rules and details before the first reply.
    @ObservationIgnored var preparing: Task<Void, Never>?
    /// Waits for the old sheet's work to stop, then solves the newly chosen one.
    @ObservationIgnored private var choosing: Task<Void, Never>?
    /// The panel closed: nothing starts another (paid) call until it opens again.
    @ObservationIgnored private(set) var closed = false
    /// The memory build, cancelled on its own by Skip for Now.
    @ObservationIgnored var memoryBuild: Task<CourseMemory.Progress, Never>?
    /// Ends the wait for indexing (indexing finished, or Skip for Now).
    @ObservationIgnored var memoryGate: AsyncStream<Void>.Continuation?
    /// Bumped after each memory build, so late progress updates of a finished build are dropped.
    @ObservationIgnored var memoryRun = 0
    /// The memory was built (or skipped) for this panel; `retryMemory` builds it again.
    @ObservationIgnored var memoryReady = false
    /// The course memory as sent to the model, made once per solve.
    @ObservationIgnored var memoryText: String?
    /// The sheet file's own text, and its material id when it is a course PDF.
    @ObservationIgnored var sheetText = ""
    @ObservationIgnored var sheetItemId: Int64?
    /// The handwriting markup of a revision (converted, and repaired if needed), so a new header
    /// writes it again without asking ChatGPT.
    @ObservationIgnored private var markup: (revision: Int, text: String)?
    /// ChatGPT calls made to turn solutions into handwriting markup (the debug checks log it).
    @ObservationIgnored private(set) var conversionCalls = 0
    /// The PDFs made for the current header, per format: what the preview shows and what is attached.
    private(set) var output: [Format: (revision: Int, data: Data)] = [:]
    /// Why the PDF of the current format couldn't be made.
    private(set) var outputError: String?
    /// Bumped whenever the PDFs go stale (a new header, a new handwriting rendering).
    @ObservationIgnored private var outputGeneration = 0
    /// PDFs being made, shared by the preview and the buttons so both get the same bytes.
    @ObservationIgnored private var making: [Format: (revision: Int, generation: Int, task: Task<Data, Error>)] = [:]

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
        // Its own course first, then the related ones (details typed on a twin course's page).
        courseDetails = CourseDetails.load(database, courseIds: courseIds)
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
        closed = false
        guard messages.isEmpty, signedIn, !needsSheet, !isBusy, preparing == nil else { return }
        if case .needsDetails = phase { return }
        prepare()
    }

    /// Uses another sheet (or none) and solves again; its rules are read again.
    func choose(_ sheet: Sheet) {
        replying?.cancel()
        preparing?.cancel()
        choosing?.cancel()
        self.sheet = sheet
        sheetChosen = true
        task = nil
        sheetText = ""
        sheetItemId = nil
        rules = nil
        rulesError = nil
        headerOverrides = [:]
        droppedFields = []
        invalidateOutput()
        if case .needsDetails = phase { phase = .idle }
        choosing = Task {
            await replying?.value
            await preparing?.value
            // Stopped or closed meanwhile (or another sheet chosen): don't pay for a solve.
            guard !Task.isCancelled else { return }
            choosing = nil
            resolve()
        }
    }

    func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Unknown rules: nothing is written until they're read or the student continues without them.
        guard !text.isEmpty, !isBusy, signedIn, rules != nil else { return }
        if case .needsDetails = phase { return }
        messages.append(Message(role: .user, text: text))
        reply(to: text)
    }

    /// Stops everything in flight: the memory build, the rules, the reply and the handwriting
    /// conversion. Also called when the panel closes. (Indexing itself can't be cancelled; it
    /// finishes in the background.)
    func stop() {
        replying?.cancel()
        preparing?.cancel()
        choosing?.cancel()
        choosing = nil
        memoryBuild?.cancel()
        converting?.cancel()
    }

    /// The panel went away: stops everything, and nothing new starts until `start()`.
    func close() {
        closed = true
        stop()
    }

    /// Starts over: a fresh solution from the task.
    func resolve() {
        guard !closed, !isBusy, preparing == nil else { return }
        messages = []
        solution = ""
        revision = 0
        handwriting = .none
        markup = nil
        invalidateOutput()
        sources = []
        excerpts = []
        memoryText = nil
        // Details still missing: ask for them again instead of solving without them.
        if rules == nil || !memoryReady || !missingDetails().isEmpty {
            prepare()
        } else {
            phase = .idle
            reply(to: nil)
        }
    }

    // MARK: - Header and filename

    /// The student's and course's details with this PDF's overrides applied. Header values come
    /// only from these, never from anything ChatGPT wrote.
    private var effectiveDetails: (student: StudentDetails, course: CourseDetails) {
        var student = student, course = courseDetails
        func value(_ field: SubmissionRules.Field) -> String? {
            guard let value = headerOverrides[field]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        if let name = value(.name) { student.name = name }
        if let matrikelnr = value(.matrikelnr) { student.matrikelnr = matrikelnr }
        if let email = value(.email) { student.email = email }
        if let group = value(.group) { course.group = group }
        if let tutorial = value(.tutorial) { course.tutorial = tutorial }
        return (student, course)
    }

    /// The rules for this PDF: as read (or none), without the fields marked not needed.
    var activeRules: SubmissionRules { (rules ?? .none).dropping(droppedFields) }

    /// Marks a field "Not needed for this sheet" (or needed again) for this PDF: it leaves the
    /// header, the file name and the details asked for. No value is filled in for it.
    func setNeeded(_ field: SubmissionRules.Field, _ needed: Bool) {
        guard SubmissionRules.droppable.contains(field) else { return }
        if needed { droppedFields.remove(field) } else { droppedFields.insert(field) }
        headerChanged()
    }

    /// The rows at the top of the PDF: the rules' fields, the course and the sheet; empty rows are left out.
    var headerRows: [(label: String, value: String)] {
        let rules = activeRules
        let (student, course) = effectiveDetails
        var rows = rules.header(student: student, course: course, courseName: courseName, sheetTitle: assignment.name)
        // Partner rows can't come from a copy of the details: override them by position.
        let partner: Set<SubmissionRules.Field> = [.partnerNames, .partnerMatrikelnr]
        let shown = rules.header.filter { $0 != .sheet && !(course.alone && partner.contains($0)) }
        for (index, field) in shown.enumerated() where index < rows.count {
            guard field == .partnerNames || field == .partnerMatrikelnr,
                  let value = headerOverrides[field]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { continue }
            rows[index].value = value
        }
        return rows.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var headerKey: [String] { headerRows.map { $0.label + "\u{1}" + $0.value } }

    /// The header changed: the PDFs are made again, and the handwriting written again (from the
    /// markup it already has).
    func headerChanged() {
        invalidateOutput()
        if case .ready = handwriting {
            handwriting = .none
            if format == .handwritten { renderHandwritingIfNeeded() }
        }
        makePreview()
    }

    private func invalidateOutput() {
        output = [:]
        outputError = nil
        outputGeneration += 1
        making = [:]
    }

    func reply(to request: String?) {
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
                makePreview()
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
    func readTask() async throws -> (text: String, images: [Data]) {
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

        var sheetText = ""
        var sheetItemId: Int64?
        switch sheet {
        case .none: break
        case .material(let candidate):
            phase = .reading("Reading \(candidate.name)…")
            let url = try await openMaterial(candidate.item)
            sheetText = add(candidate.item.filename ?? candidate.name, try Data(contentsOf: url))
            sheetItemId = candidate.item.id
        case .file(let name, let data):
            sheetText = add(name, data)
        }
        for (number, file) in assignment.attachments.enumerated() {
            phase = .reading("Reading \(file.filename) (\(number + 1) of \(assignment.attachments.count))…")
            add(file.filename, try await service.download(file).data)
        }
        if !images.isEmpty { parts.append("The pages of the files above are attached as images; where the extracted text is garbled, the images are right.") }
        let task = (parts.joined(separator: "\n\n"), images)
        // Cancelled (another sheet was chosen): don't cache this sheet's text.
        try Task.checkCancellation()
        self.task = task
        self.sheetText = sheetText
        self.sheetItemId = sheetItemId
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
            // One budget for the whole Solve: follow-ups get what the earlier excerpts left.
            let budget = SolveContext.excerptBudget - excerpts.reduce(0) { $0 + $1.text.count }
            if budget > 0, let new = try? SolveContext.excerpts(retriever: retriever, tasks: queries, courseIds: courseIds,
                                                                already: already, budget: budget) {
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

        The app puts the header on the PDF itself: the student's name and IDs, the course and the \
        sheet's title. So start the solution directly with the first task: no title, no sheet name, \
        and no name, ID or date fields.

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
        invalidateOutput()
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
        // The header is added only for the render: it never goes to ChatGPT or into its repairs.
        let header = headerRows
        let key = headerKey
        converting = Task {
            do {
                let rendering: Handwriter.Rendering
                if let markup, markup.revision == target {
                    handwriting = .rendering
                    rendering = try await Handwriter.render(markup.text, strict: false, header: header)
                } else {
                    handwriting = .converting
                    var markup = try await convert(solution, fixing: nil)
                    handwriting = .rendering
                    do {
                        rendering = try await Handwriter.render(markup, strict: true, header: header)
                    } catch Handwriter.Failure.invalidMarkup(let errors) {
                        // One repair round with the validator's errors, then render whatever is left.
                        handwriting = .converting
                        markup = try await convert(markup, fixing: errors)
                        handwriting = .rendering
                        rendering = try await Handwriter.render(markup, strict: false, header: header)
                    }
                    try Task.checkCancellation()
                    self.markup = (target, markup)
                }
                try Task.checkCancellation()
                if key == headerKey {
                    handwriting = .ready(rendering, revision: target)
                    output[.handwritten] = nil
                    outputGeneration += 1
                } else {
                    handwriting = .none  // the header changed meanwhile: written again below
                }
            } catch is CancellationError {
                handwriting = .none  // stopped; rendered again when the handwritten view shows
            } catch _ where Task.isCancelled {
                handwriting = .none
            } catch Handwriter.Failure.notSetUp {
                handwriting = .notSetUp
            } catch let failure as Handwriter.Failure {
                handwriting = .failed(failure.errorDescription ?? "Math Writer failed.")
            } catch {
                handwriting = .failed(AskModel.describe(error))
            }
            converting = nil
            // The solution or the header changed while this one rendered: render the new one.
            if !Task.isCancelled, target != revision || key != headerKey { renderHandwritingIfNeeded() }
            makePreview()
        }
    }

    /// Markdown + LaTeX → Math Writer markup, or a repair of markup the validator rejected.
    private func convert(_ text: String, fixing errors: [String]?) async throws -> String {
        guard let model = ask.model else { throw ChatGPTError.notSignedIn }
        conversionCalls += 1
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
    /// With `markup`, the handwritten version is written from it (no conversion call); the details
    /// are shown, never saved.
    func showDemo(request: String, note: String, solution: String, markup: String?,
                  rules: SubmissionRules = .none, student: StudentDetails? = nil, course: CourseDetails? = nil) {
        messages = [Message(role: .assistant, text: "Here's a full solution."), Message(role: .user, text: request),
                    Message(role: .assistant, text: note)]
        self.solution = solution
        sheetChosen = true
        self.rules = rules
        if let student { self.student = student }
        if let course { courseDetails = course }
        memoryReady = true
        revision = 2
        phase = .idle
        handwriting = .none
        invalidateOutput()
        if let markup { self.markup = (revision, markup) }
        if format == .handwritten { renderHandwritingIfNeeded() }
        makePreview()
    }

    #if DEBUG
    /// Debug screenshots (--solve-check): the rules call failed before the first solution.
    func showDemoRulesFailed(_ message: String) {
        messages = []
        solution = ""
        revision = 0
        rules = nil
        rulesError = message
        phase = .idle
        handwriting = .none
        invalidateOutput()
    }
    #endif

    /// Debug screenshots (--solve-check): puts the panel into a state without running it.
    func showDemoState(phase: Phase, unread: [(title: String, reason: String)] = [],
                       sources: [SolveReply.Source] = [], excerpts: [Excerpt] = [],
                       student: StudentDetails? = nil, course: CourseDetails? = nil) {
        self.phase = phase
        self.unread = unread
        self.sources = sources
        self.excerpts = excerpts
        if let student { self.student = student }
        if let course { courseDetails = course }
    }

    // MARK: - Output

    /// The rules' file name pattern filled in from the details (and this PDF's overrides).
    var suggestedFilename: String {
        let (student, course) = effectiveDetails
        let sheet = headerOverrides[.sheet].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? sheetNumber
        return activeRules.filename(student: student, course: course, assignment: assignment.name, sheet: sheet, courseShort: courseShort)
    }

    /// The solution as a PDF in the chosen format, with the header: the cached one for this
    /// revision and header, or a new one (cached).
    func pdf() async throws -> Data {
        let format = format
        while true {
            if let cached = output[format], cached.revision == revision { return cached.data }
            let revision = revision, generation = outputGeneration
            let task: Task<Data, Error>
            if let current = making[format], current.revision == revision, current.generation == generation {
                task = current.task
            } else {
                task = Task { try await self.make(format) }
                making[format] = (revision, generation, task)
            }
            let data: Data
            do {
                data = try await task.value
            } catch {
                // A failed PDF isn't kept: the next call (Try Again) makes it again.
                if making[format]?.task == task { making[format] = nil }
                throw error
            }
            // Stale (a new header or solution while it was made): make it again.
            guard revision == self.revision, generation == outputGeneration else { continue }
            if output[format]?.revision != revision { output[format] = (revision, data) }
            if format == self.format { outputError = nil }
            making[format] = nil
            return output[format]!.data
        }
    }

    private func make(_ format: Format) async throws -> Data {
        switch format {
        case .typed:
            return try await SolutionPDF.make(markdown: solution, title: assignment.name, header: headerRows)
        case .handwritten:
            guard case .ready(let rendering, let rendered) = handwriting, rendered == revision else {
                throw Handwriter.Failure.failed("The handwritten version isn't ready yet.")
            }
            return try Data(contentsOf: rendering.pdf)
        }
    }

    /// Makes the current format's PDF for the preview, once the solution is done.
    func makePreview() {
        guard canExport, output[format]?.revision != revision else { return }
        let format = format
        Task {
            do {
                _ = try await pdf()
            } catch {
                if self.format == format, !(error is CancellationError) {
                    outputError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }

    /// The file name and the PDF to add to the submission: the bytes the preview shows.
    func attachment() async throws -> (filename: String, data: Data) {
        let data = try await pdf()
        return (suggestedFilename, data)
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
