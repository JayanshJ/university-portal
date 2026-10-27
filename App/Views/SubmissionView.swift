import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UniversityKit

/// A Moodle assignment to hand in, chosen from a deadline.
struct SubmitTarget: Identifiable, Hashable {
    let itemId: Int64
    let cmid: Int
    var id: Int64 { itemId }
}

/// Loads an assignment's rules and current submission, holds the files and text being handed in,
/// and saves or submits them.
@MainActor @Observable
final class SubmissionModel {
    enum Phase: Equatable {
        case loading
        case ready
        case working(String)
        case failed(String)
    }

    /// A file in the submission: one already on Moodle, or one picked on this Mac.
    struct Entry: Identifiable, Equatable {
        enum Source: Equatable {
            case moodle(SubmittedFile)
            case local(Data)
        }

        let id = UUID()
        var filename: String
        var size: Int64
        var source: Source
    }

    let cmid: Int
    private let service: MoodleSubmissions
    private(set) var rules: AssignmentRules?
    private(set) var state: SubmissionState?
    private(set) var phase: Phase = .loading
    /// Set after a save or submit, e.g. "Submitted for grading."
    private(set) var confirmation: String?
    var files: [Entry] = []
    var text = ""
    var acceptStatement = false

    init(cmid: Int, service: MoodleSubmissions) {
        self.cmid = cmid
        self.service = service
    }

    func load() async {
        phase = .loading
        do {
            let rules = try await service.rules(cmid: cmid)
            let state = try await service.state(assignId: rules.assignId)
            self.rules = rules
            apply(state)
            phase = .ready
        } catch {
            phase = .failed(Self.describe(error))
        }
    }

    private func apply(_ state: SubmissionState) {
        self.state = state
        files = state.files.map { Entry(filename: $0.filename, size: $0.size, source: .moodle($0)) }
        text = state.text ?? ""
    }

    var canEdit: Bool { state?.canEdit == true }

    /// Final submission: "Submit for grading" when the assignment uses drafts, otherwise saving submits.
    var finalTitle: String { rules?.usesDrafts == true ? "Submit for Grading" : "Submit" }

    // MARK: - Files

    /// Adds picked or dropped files; a file with the same name replaces the earlier one.
    func add(_ urls: [URL]) {
        var unreadable: [String] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                unreadable.append(url.lastPathComponent)
                continue
            }
            files.removeAll { $0.filename == url.lastPathComponent }
            files.append(Entry(filename: url.lastPathComponent, size: Int64(data.count), source: .local(data)))
        }
        phase = unreadable.isEmpty ? .ready : .failed("Couldn't read \(unreadable.joined(separator: ", ")).")
    }

    func remove(_ entry: Entry) {
        files.removeAll { $0.id == entry.id }
    }

    /// The extensions the assignment allows, when it lists them (".pdf"); nil = any, or groups Moodle checks itself.
    var allowedExtensions: [String]? {
        guard let types = rules?.fileTypes, !types.isEmpty, types.allSatisfy({ $0.hasPrefix(".") }) else { return nil }
        return types.map { $0.dropFirst().lowercased() }
    }

    var limitsText: String {
        guard let rules else { return "" }
        var parts = [rules.maxFiles == 1 ? "1 file" : "Up to \(rules.maxFiles) files"]
        if rules.maxBytes > 0 { parts.append("\(Self.moodleSize(rules.maxBytes)) each") }
        if !rules.fileTypes.isEmpty { parts.append(rules.fileTypes.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    /// What stops handing in, in plain words; empty when it can go.
    var problems: [String] {
        guard let rules else { return [] }
        var problems: [String] = []
        if rules.acceptsFiles {
            if files.count > rules.maxFiles {
                problems.append("Remove \(files.count - rules.maxFiles) file\(files.count - rules.maxFiles == 1 ? "" : "s"): this assignment takes \(rules.maxFiles == 1 ? "1 file" : "up to \(rules.maxFiles) files").")
            }
            if rules.maxBytes > 0, let big = files.first(where: { $0.size > rules.maxBytes }) {
                problems.append("\(big.filename) is larger than \(Self.moodleSize(rules.maxBytes)).")
            }
            if let allowed = allowedExtensions,
               let wrong = files.first(where: { !allowed.contains(($0.filename as NSString).pathExtension.lowercased()) }) {
                problems.append("\(wrong.filename) isn't an allowed type (\(rules.fileTypes.joined(separator: ", "))).")
            }
        }
        if let limit = rules.wordLimit, wordCount > limit {
            problems.append("The text has \(wordCount) words; the limit is \(limit).")
        }
        if files.isEmpty && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            problems.append(rules.acceptsFiles ? "Add a file to hand in." : "Write your answer first.")
        }
        return problems
    }

    /// Limits as Moodle shows them: 20971520 bytes is "20 MB".
    static func moodleSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }

    var wordCount: Int { text.split(whereSeparator: \.isWhitespace).count }

    // MARK: - Saving

    /// Saves the files and text; with `final`, also submits for grading (when the assignment uses drafts).
    func save(final: Bool) async {
        guard let rules, problems.isEmpty else { return }
        confirmation = nil
        do {
            var upload: [SubmissionFile] = []
            if rules.acceptsFiles {
                for (index, entry) in files.enumerated() {
                    switch entry.source {
                    case .local(let data):
                        upload.append(SubmissionFile(filename: entry.filename, data: data))
                    case .moodle(let file):
                        phase = .working("Keeping \(entry.filename) (\(index + 1) of \(files.count))…")
                        upload.append(try await service.download(file))
                    }
                }
            }
            phase = .working(upload.isEmpty ? "Saving…" : "Uploading \(upload.count) file\(upload.count == 1 ? "" : "s")…")
            try await service.save(assignId: rules.assignId, files: rules.acceptsFiles ? upload : nil,
                                   text: rules.acceptsText ? text : nil)
            if final && rules.usesDrafts {
                phase = .working("Submitting for grading…")
                try await service.submitForGrading(assignId: rules.assignId, acceptStatement: acceptStatement)
            }
            apply(try await service.state(assignId: rules.assignId))
            confirmation = final ? "Submitted. Moodle has your files." : "Draft saved on Moodle. It isn't submitted for grading yet."
            phase = .ready
        } catch {
            phase = .failed(Self.describe(error))
        }
    }

    func openAttachment(_ file: SubmittedFile) async {
        do {
            let downloaded = try await service.download(file)
            let folder = FileManager.default.temporaryDirectory.appending(path: "assignment-\(cmid)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appending(path: downloaded.filename)
            try downloaded.data.write(to: url)
            NSWorkspace.shared.open(url)
        } catch {
            phase = .failed(Self.describe(error))
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case SubmissionError.notAnAssignment: "This isn't a Moodle assignment, so it can't be handed in from here."
        case SubmissionError.refused(let message): "Moodle didn't accept it: \(HTMLText.plainText(message))"
        case SubmissionError.upload(let message): "The upload failed: \(message)"
        case MoodleError.invalidToken: "Moodle needs reconnecting (Settings → Moodle)."
        case MoodleError.moodle(let code, let message) where code == "accessexception" || code == "webservice_access_exception":
            "Your Moodle connection isn't allowed to do this (\(message)). Use Open in Moodle."
        case MoodleError.moodle(_, let message): "Moodle: \(HTMLText.plainText(message))"
        case let error as URLError where error.code == .notConnectedToInternet: "You're offline."
        default: Redactor.redact(String(describing: error))
        }
    }
}

/// The hand-in sheet: the task, the files and text being submitted, and Save Draft / Submit.
struct SubmissionView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State var model: SubmissionModel
    let item: PortalOverview.ItemRow?
    @State private var importing = false
    @State private var confirmingFinal = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 600, height: 640)
        .task { await model.load() }
        .fileImporter(isPresented: $importing, allowedContentTypes: allowedTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.add(urls) }
        }
        .confirmationDialog("\(model.finalTitle)?", isPresented: $confirmingFinal) {
            Button(model.finalTitle) { Task { await finish(final: true) } }
        } message: {
            Text(model.rules?.usesDrafts == true
                 ? "Once it's submitted for grading you can't change it, unless your tutor reverts it to a draft."
                 : "Moodle will have exactly these files\(model.rules?.acceptsText == true ? " and text" : "").")
        }
    }

    private var allowedTypes: [UTType] {
        guard let extensions = model.allowedExtensions else { return [.item] }
        let types = extensions.compactMap { UTType(filenameExtension: $0) }
        return types.isEmpty ? [.item] : types
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.rules?.name ?? item?.title ?? "Assignment").font(.title2.weight(.semibold)).lineLimit(2)
                Spacer()
                if let state = model.state { statusTag(state) }
            }
            HStack(spacing: 6) {
                if let item { Text(app.overview.style(for: item.courseId).name) }
                if let due = model.state?.extensionDue ?? model.rules?.dueDate ?? item?.date {
                    Text("·")
                    Text("Due \(DueText.date(due)) (\(DueText.relative(due)))").foregroundStyle(DueText.color(due))
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private func statusTag(_ state: SubmissionState) -> some View {
        switch state.status {
        case _ where state.graded: Tag(state.grade.map { "Graded: \($0)" } ?? "Graded", color: Theme.done)
        case .submitted: Tag(model.rules?.usesDrafts == true ? "Submitted for grading" : "Submitted", color: Theme.done)
        case .draft: Tag("Draft, not submitted")
        case .reopened: Tag("Reopened")
        case .new: Tag("Not submitted", color: .secondary)
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading where model.rules == nil:
            ProgressView("Loading the assignment…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message) where model.rules == nil:
            ContentUnavailableView {
                Label("Couldn't Load the Assignment", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await model.load() } }
            }
        default:
            if let rules = model.rules { form(rules) }
        }
    }

    private func form(_ rules: AssignmentRules) -> some View {
        Form {
            if !rules.intro.isEmpty || !rules.attachments.isEmpty {
                Section("Task") {
                    if !rules.intro.isEmpty {
                        Text(rules.intro).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(rules.attachments, id: \.self) { file in
                        Button { Task { await model.openAttachment(file) } } label: {
                            HStack {
                                FileIcon(filename: file.filename, size: 18)
                                Text(file.filename)
                                Spacer()
                                Text(file.size.fileSizeText).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Open")
                    }
                }
            }

            if rules.acceptsFiles {
                Section {
                    if model.files.isEmpty {
                        Text(model.canEdit ? "Drop files here or click Add Files." : "No files.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.files) { entry in
                        HStack {
                            FileIcon(filename: entry.filename, size: 18)
                            Text(entry.filename).lineLimit(1)
                            if case .moodle = entry.source { Text("on Moodle").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Text(entry.size.fileSizeText).foregroundStyle(.secondary)
                            if model.canEdit {
                                Button { model.remove(entry) } label: { Image(systemName: "minus.circle.fill") }
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(.secondary)
                                    .help("Remove")
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Files")
                        Spacer()
                        if model.canEdit { Button("Add Files…") { importing = true }.buttonStyle(.link) }
                    }
                } footer: {
                    Text(model.limitsText).font(.caption).foregroundStyle(.secondary)
                }
                .dropDestination(for: URL.self) { urls, _ in
                    guard model.canEdit else { return false }
                    model.add(urls)
                    return true
                }
            }

            if rules.acceptsText {
                Section {
                    TextEditor(text: $model.text)
                        .font(.body)
                        .frame(minHeight: 120)
                        .disabled(!model.canEdit)
                } header: {
                    Text("Online Text")
                } footer: {
                    Text(rules.wordLimit.map { "\(model.wordCount) of \($0) words" } ?? "\(model.wordCount) words")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if rules.requiresStatement && model.canEdit {
                Section {
                    Toggle(isOn: $model.acceptStatement) {
                        Text(rules.statement ?? "This submission is my own work, except where I have acknowledged the work of others.")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if !model.canEdit, let state = model.state {
                Section {
                    Label(lockedMessage(state), systemImage: "lock")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(isWorking)
    }

    private func lockedMessage(_ state: SubmissionState) -> String {
        if state.graded { return "This assignment has been graded." }
        if state.status == .submitted { return "Submitted for grading\(state.modified.map { " on \(DueText.date($0))" } ?? ""). To change it, ask your tutor to revert it to a draft." }
        if state.locked { return "Submissions are locked for you." }
        return "Moodle isn't accepting submissions for this assignment right now."
    }

    // MARK: Footer

    private var isWorking: Bool { if case .working = model.phase { true } else { false } }

    private var footer: some View {
        HStack(spacing: 10) {
            if let item, let link = item.url.flatMap(URL.init(string:)) {
                Link("Open in Moodle", destination: link)
            }
            Spacer()
            status
            Button(model.canEdit ? "Cancel" : "Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
            if model.canEdit, let rules = model.rules {
                if rules.usesDrafts {
                    Button("Save Draft") { Task { await finish(final: false) } }
                        .disabled(isWorking || !model.problems.isEmpty)
                }
                Button(model.finalTitle) { confirmingFinal = true }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking || !model.problems.isEmpty || (rules.requiresStatement && !model.acceptStatement))
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var status: some View {
        Group {
            switch model.phase {
            case .working(let message):
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text(message) }
            case .failed(let message) where model.rules != nil:
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.overdue)
            default:
                if let confirmation = model.confirmation {
                    Label(confirmation, systemImage: "checkmark.circle.fill").foregroundStyle(Theme.done)
                } else if model.canEdit, let problem = model.problems.first, !(model.files.isEmpty && model.text.isEmpty) {
                    Text(problem).foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
        .lineLimit(2)
        .frame(maxWidth: 300, alignment: .trailing)
    }

    private func finish(final: Bool) async {
        await model.save(final: final)
        if model.confirmation != nil { await app.syncNow() }
    }
}
