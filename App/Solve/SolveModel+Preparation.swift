import Foundation
import UniversityKit

/// Before the first reply: the course memory, the sheet's submission rules and the details they need.
/// (Moved out of SolveModel.swift; the state it writes, such as `phase`, is internal for it: views only read it.)
extension SolveModel {
    // MARK: - Memory, rules and details

    /// Before the first reply: the course memory, the files it can't read, the sheet's submission
    /// rules, and the student's details those rules need.
    func prepare() {
        preparing = Task {
            defer { preparing = nil }
            do {
                if !memoryReady { await buildMemory() }
                try Task.checkCancellation()
                if rules == nil {
                    let task = try await readTask()
                    let read = try await readRules(task)
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

    /// One call: the sheet's header fields, file name pattern and other submission rules. Falls back
    /// to `.none` when ChatGPT fails.
    func readRules(_ task: (text: String, images: [Data])) async throws -> SubmissionRules {
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

    func memoryDocument() -> MemoryDocument? {
        guard let memoryCourseId = courseIds.first, let memory = ask.memory() else { return nil }
        return try? memory.document(memoryCourseId: memoryCourseId, courseIds: courseIds)
    }

    /// Fields the rules need that are still empty and not typed in for this PDF.
    func missingDetails() -> [SubmissionRules.Field] {
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
