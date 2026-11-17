import Foundation
import UniversityKit

/// Before the first reply: the course memory, the sheet's submission rules and the details they need.
/// (Moved out of SolveModel.swift; the state it writes, such as `phase`, is internal for it: views only read it.)
extension SolveModel {
    // MARK: - Memory, rules and details

    /// Before the first reply: the course memory, the files it can't read, the sheet's submission
    /// rules, and the student's details those rules need.
    func prepare() {
        guard !closed else { return }
        preparing = Task {
            defer { preparing = nil }
            do {
                if !memoryReady { await buildMemory() }
                try Task.checkCancellation()
                if rules == nil {
                    rulesError = nil
                    let task = try await readTask()
                    let read: SubmissionRules
                    do {
                        read = try await readRules(task)
                    } catch let failure as RulesFailure {
                        // Not "no rules": wait for Retry or Continue Without Rules.
                        rulesError = failure.message
                        phase = .idle
                        // Signed out: the panel shows the sign-in again instead of a Retry that can't work.
                        if failure.expired { await ask.refreshAccount() }
                        return
                    }
                    try Task.checkCancellation()  // another sheet was chosen meanwhile
                    rules = read
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
    func buildMemory() async {
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

    /// The rules call failed (or its reply held no rules): unknown, not "no rules".
    struct RulesFailure: Error {
        var message: String
        /// The ChatGPT sign-in expired (the account is refreshed).
        var expired = false
    }

    /// Reads the rules again after a failure; continues to the solution when they're read.
    func retryRules() {
        guard rules == nil, !isBusy, preparing == nil else { return }
        rulesError = nil
        prepare()
    }

    /// The student chose to go on without the sheet's rules: only the name is asked for.
    func continueWithoutRules() {
        guard rules == nil, !isBusy, preparing == nil else { return }
        rules = SubmissionRules.none
        rulesError = nil
        prepare()
    }

    /// One call: the sheet's header fields, file name pattern and other submission rules. Throws
    /// `RulesFailure` when the call fails or its reply holds no rules.
    func readRules(_ task: (text: String, images: [Data])) async throws -> SubmissionRules {
        guard let model = ask.model else { throw RulesFailure(message: AskModel.describe(ChatGPTError.notSignedIn)) }
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
            guard let rules = SubmissionRules.decode(reply) else {
                throw RulesFailure(message: "The answer held no rules.")
            }
            return rules
        } catch let failure as RulesFailure {
            throw failure
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw RulesFailure(message: AskModel.describe(error), expired: error as? ChatGPTError == .signInExpired)
        }
    }

    func memoryDocument() -> MemoryDocument? {
        guard let memoryCourseId = courseIds.first, let memory = ask.memory() else { return nil }
        return try? memory.document(memoryCourseId: memoryCourseId, courseIds: courseIds)
    }

    /// Fields the rules need that are still empty and not typed in for this PDF.
    /// With `student`, `course` and `sheet`, for values typed in the details form but not saved yet:
    /// the one rule for what is missing, shared by the model and the form.
    func missingDetails(student: StudentDetails? = nil, course: CourseDetails? = nil, sheet: String? = nil) -> [SubmissionRules.Field] {
        var overrides = headerOverrides
        if let sheet { overrides[.sheet] = sheet }
        let number = overrides[.sheet].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? sheetNumber
        return activeRules.missing(student: student ?? self.student, course: course ?? courseDetails, sheet: number).filter {
            // The sheet number counts only as a number (the file name needs one); `missing` checked it.
            $0 == .sheet || (overrides[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Saves the student's and the course's details and, when Solve was waiting for them, solves.
    func saveDetails(student: StudentDetails, course: CourseDetails) {
        try? student.save(database)
        if let courseId = courseIds.first { try? course.save(database, courseId: courseId) }
        courseDetails = course
        studentChanged(student)
    }

    /// Uses new student details (already saved) and, when Solve was waiting for them, solves.
    private func studentChanged(_ student: StudentDetails) {
        self.student = student
        headerChanged()
        guard case .needsDetails = phase else { return }
        // Never put a blank identity field into the PDF without asking: stay until all are given.
        let missing = missingDetails()
        if !missing.isEmpty {
            phase = .needsDetails(missing)
            return
        }
        phase = .idle
        reply(to: nil)
    }

    /// Takes over the student's details when they were changed elsewhere (Settings).
    func reloadStudent() {
        let stored = StudentDetails.load(database)
        // Course details stay where they are: copying them under this course would hide later
        // edits made on a related course's page.
        if stored != student { studentChanged(stored) }
    }

    /// A header value for this PDF only (not saved).
    func overrideHeader(_ field: SubmissionRules.Field, value: String) {
        headerOverrides[field] = value
        headerChanged()
    }

    /// A header field's value for this PDF: the override when one is typed, else the stored details.
    func headerValue(_ field: SubmissionRules.Field) -> String {
        if let value = headerOverrides[field]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { return value }
        switch field {
        case .name: return student.name
        case .matrikelnr: return student.matrikelnr
        case .email: return student.email
        case .group: return courseDetails.group
        case .tutorial: return courseDetails.tutorial
        case .sheet: return sheetNumber.map(String.init) ?? ""
        case .partnerNames: return courseDetails.partners.map(\.name).joined(separator: ", ")
        case .partnerMatrikelnr: return courseDetails.partners.map(\.matrikelnr).joined(separator: ", ")
        }
    }

    /// The memory heading a "memory: <section>" source means. The model doesn't always copy the
    /// heading exactly, so it matches case-insensitively by containment; nil when none matches.
    func memoryHeading(for section: String) -> String? {
        let wanted = section.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty, let document = memoryDocument() else { return nil }
        let headings = ["Your notes", "Course overview"] + document.files.map { file in
            file.section.map { $0.isEmpty ? file.title : "\(file.title) (\($0))" } ?? file.title
        }
        return headings.first { $0.lowercased() == wanted }
            ?? headings.first { $0.lowercased().contains(wanted) || wanted.contains($0.lowercased()) }
    }
}
