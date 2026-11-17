import SwiftUI
import UniversityKit

/// What Solve remembers about a course, to read and edit: the student's notes, the overview, one
/// summary per file, the files not read yet, and the course's submission details. Nothing here
/// calls ChatGPT: Re-read and Rebuild only mark files, and Solve reads them the next time it runs.
struct CourseMemoryView: View {
    let database: UniDatabase
    /// The course's name, for the title.
    let courseName: String
    /// The course and its related courses (the memory reads all of their PDFs).
    let courseIds: [Int64]
    /// The course the notes, overview and details are saved under; nil = the one that already has
    /// them (from the course page), else the first id.
    let memoryCourseId: Int64?
    /// A heading as Solve names it ("Your notes", "Course overview" or a file's title), to scroll to.
    let heading: String?

    @Environment(\.dismiss) private var dismiss
    @State private var summary: MemorySummary?
    @State private var document: MemoryDocument?
    @State private var loaded = false
    @State private var notes = ""
    @State private var savedNotes = ""
    @State private var details = CourseDetails()
    @State private var savedDetails = CourseDetails()
    @State private var editingOverview: String?
    @State private var expanded: Set<Int64> = []
    @State private var reread: Set<Int64> = []
    @State private var rebuilt = false
    @State private var confirmingRebuild = false
    @State private var error: String?

    private var memory: CourseMemory { .viewer(database) }
    private var keyCourse: Int64? { memoryCourseId ?? summary?.memoryCourseId ?? courseIds.first }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                Form {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Course Memory").font(.headline)
                            Text(subtitle).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    if let document {
                        memorySections(document)
                    } else if loaded {
                        Section {
                            Text("Built the first time you use Solve in this course.").foregroundStyle(.secondary)
                        }
                    }
                    detailsSections
                }
                .formStyle(.grouped)
                .textFieldStyle(.roundedBorder)
                .scrollContentBackground(.hidden)
                .task {
                    load()
                    await scroll(proxy)
                }
            }

            Divider()
            HStack {
                Button("Rebuild…") { confirmingRebuild = true }
                    .disabled(document == nil)
                    .help("Read every file again the next time you use Solve")
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
                Spacer()
                Button("Done") {
                    saveNotes()
                    saveDetails()
                    dismiss()
                }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 680)
        .task(id: notes) {
            guard notes != savedNotes else { return }
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { saveNotes() }
        }
        .task(id: details) {
            guard details != savedDetails else { return }
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { saveDetails() }
        }
        .onDisappear {
            saveNotes()
            saveDetails()
        }
        .confirmationDialog("Re-read every file?", isPresented: $confirmingRebuild) {
            Button("Rebuild", role: .destructive, action: rebuild)
        } message: {
            Text("Your notes are kept; edits to the overview and file summaries are replaced.")
        }
    }

    private var subtitle: String {
        guard let summary else { return courseName }
        return [courseName, Self.summaryText(summary)].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// "22 files · updated 2 hr. ago"
    static func summaryText(_ summary: MemorySummary) -> String {
        let files = summary.files == 1 ? "1 file" : "\(summary.files) files"
        return "\(files) · updated \(summary.updatedAt.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))"
    }

    // MARK: Sections

    @ViewBuilder
    private func memorySections(_ document: MemoryDocument) -> some View {
        Section {
            TextEditor(text: $notes)
                .font(.body)
                .frame(minHeight: 70)
                .accessibilityLabel("Your notes")
        } header: {
            Text("Your Notes")
        } footer: {
            Text("Solve reads these with every sheet. Updates and Rebuild never change them.").foregroundStyle(.secondary)
        }
        .id(ScrollTarget.notes)

        Section {
            if let draft = editingOverview {
                TextEditor(text: Binding(get: { draft }, set: { editingOverview = $0 }))
                    .font(.body)
                    .frame(minHeight: 160)
                    .accessibilityLabel("Course overview")
                EditButtons(cancel: { editingOverview = nil }, save: { saveOverview(draft) })
            } else if document.overview.isEmpty {
                Text("Written once Solve has read the files.").foregroundStyle(.secondary)
            } else {
                MemoryMarkdown(text: document.overview)
            }
        } header: {
            HStack {
                Text("Course Overview")
                Spacer()
                if editingOverview == nil {
                    Button("Edit") { editingOverview = document.overview }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .help("Edit the overview; Solve keeps your version until you rebuild")
                }
            }
        }
        .id(ScrollTarget.overview)

        if !document.files.isEmpty {
            Section("Files") {
                ForEach(document.files, id: \.itemId) { file in
                    MemoryFileRow(file: file, isExpanded: expandedBinding(file.itemId), reread: reread.contains(file.itemId),
                                  save: { saveDigest($0, itemId: file.itemId) }, rereadNow: { rereadFile(file.itemId) })
                        .id(ScrollTarget.file(file.itemId))
                }
            }
        }

        if !document.unread.isEmpty {
            Section {
                ForEach(Array(document.unread.enumerated()), id: \.offset) { _, file in
                    LabeledContent {
                        Text(file.reason).foregroundStyle(.secondary)
                    } label: {
                        Text(file.title)
                    }
                }
            } header: {
                Text("Not Read Yet")
            } footer: {
                Text("Solve tries these again the next time it runs.").foregroundStyle(.secondary)
            }
        }

        if rebuilt {
            Section {
                Text("Every file is read again the next time you use Solve in this course.").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var detailsSections: some View {
        Section {
            TextField("Group", text: $details.group)
            TextField("Tutorial", text: $details.tutorial)
        } header: {
            Text("Submission Details")
        } footer: {
            Text("Saved for this course; they go into the header and file name of Solve's PDFs when a sheet asks for them.")
                .foregroundStyle(.secondary)
        }
        PartnerSections(course: $details)
    }

    private func expandedBinding(_ id: Int64) -> Binding<Bool> {
        Binding(get: { expanded.contains(id) },
                set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } })
    }

    // MARK: Loading and saving

    private func load() {
        do {
            summary = try memory.summary(courseIds: courseIds)
            if let key = keyCourse {
                let fresh = CourseDetails.load(database, courseId: key)
                if !loaded { details = fresh }
                savedDetails = fresh
            }
            if summary != nil, let key = keyCourse {
                let document = try memory.document(memoryCourseId: key, courseIds: courseIds)
                if !loaded {
                    notes = document.notes
                    savedNotes = document.notes
                }
                self.document = document
            } else {
                document = nil
            }
        } catch {
            self.error = "Couldn't read the memory: \(error.localizedDescription)"
        }
        loaded = true
    }

    /// Scrolls to the heading Solve named and opens that file's summary.
    private func scroll(_ proxy: ScrollViewProxy) async {
        guard let heading, let document else { return }
        let wanted = heading.lowercased()
        let anchor: ScrollTarget
        if wanted == "your notes" {
            anchor = .notes
        } else if wanted == "course overview" {
            anchor = .overview
        } else if let file = document.files.first(where: { $0.title.lowercased() == wanted })
                    ?? document.files.first(where: { wanted.hasPrefix($0.title.lowercased()) }) {
            expanded.insert(file.itemId)
            anchor = .file(file.itemId)
        } else {
            return
        }
        // Let the form lay out the opened group first.
        try? await Task.sleep(for: .milliseconds(300))
        withAnimation { proxy.scrollTo(anchor, anchor: .top) }
    }

    private func saveNotes() {
        guard notes != savedNotes, document != nil, let key = keyCourse else { return }
        perform { try memory.setNotes(notes, courseId: key) }
        savedNotes = notes
    }

    private func saveDetails() {
        guard details != savedDetails, let key = keyCourse else { return }
        let cleaned = details.cleaned
        perform { try cleaned.save(database, courseId: key) }
        savedDetails = details
    }

    private func saveOverview(_ text: String) {
        guard let key = keyCourse else { return }
        if text != document?.overview { perform { try memory.setOverview(text, courseId: key) } }
        editingOverview = nil
        load()
    }

    private func saveDigest(_ text: String, itemId: Int64) {
        perform { try memory.setDigest(text, itemId: itemId) }
        reread.remove(itemId)
        load()
    }

    private func rereadFile(_ itemId: Int64) {
        perform { try memory.reread(itemId: itemId) }
        reread.insert(itemId)
        load()
    }

    private func rebuild() {
        guard let key = keyCourse else { return }
        perform { try memory.rebuild(memoryCourseId: key, courseIds: courseIds) }
        rebuilt = true
        reread = Set(document?.files.map(\.itemId) ?? [])
        load()
    }

    private func perform(_ change: () throws -> Void) {
        do {
            try change()
            error = nil
        } catch {
            self.error = "Couldn't save: \(error.localizedDescription)"
        }
    }

    private enum ScrollTarget: Hashable {
        case notes, overview
        case file(Int64)
    }
}

/// One file's summary: folded by default, with an "edited" badge, and Edit or Re-read.
private struct MemoryFileRow: View {
    let file: MemoryDocument.Entry
    @Binding var isExpanded: Bool
    /// Marked to be read again; the summary shown is the old one until Solve runs.
    let reread: Bool
    let save: (String) -> Void
    let rereadNow: () -> Void
    @State private var draft: String?

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                if file.changedSinceEdit {
                    HStack {
                        Label("This file changed since you edited it.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Theme.dueSoon)
                        Spacer()
                        Button("Re-read", action: rereadNow)
                            .help("Drop your edit and read the new file the next time you use Solve")
                    }
                    .font(.callout)
                }
                if reread {
                    Text("Read again the next time you use Solve.").font(.callout).foregroundStyle(.secondary)
                }
                if let draft {
                    TextEditor(text: Binding(get: { draft }, set: { self.draft = $0 }))
                        .font(.body)
                        .frame(minHeight: 160)
                        .accessibilityLabel("Summary of \(file.title)")
                    EditButtons(cancel: { self.draft = nil }, save: {
                        if draft != file.digest { save(draft) }
                        self.draft = nil
                    })
                } else {
                    MemoryMarkdown(text: file.digest)
                    HStack {
                        Spacer()
                        Button("Edit") { draft = file.digest }
                            .controlSize(.small)
                            .help("Edit this summary; Solve keeps your version even if the file changes")
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Text(file.title).lineLimit(1).truncationMode(.middle)
                if file.edited {
                    Text("edited")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .foregroundStyle(.secondary)
                }
                if file.changedSinceEdit {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.dueSoon)
                        .accessibilityLabel("Changed since you edited it")
                }
            }
        }
    }
}

private struct EditButtons: View {
    let cancel: () -> Void
    let save: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button("Cancel", action: cancel)
            Button("Save", action: save).buttonStyle(.borderedProminent)
        }
        .controlSize(.small)
    }
}

/// Light Markdown for summaries: headings, bullets and inline styles; formulas stay as written.
struct MemoryMarkdown: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let line):
                    Text(Self.inline(line)).font(.headline).padding(.top, 4)
                case .bullet(let marker, let line):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker).foregroundStyle(.secondary)
                        Text(Self.inline(line))
                    }
                    .padding(.leading, 4)
                case .paragraph(let line):
                    Text(Self.inline(line))
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    enum Block {
        case heading(String)
        case bullet(String, String)
        case paragraph(String)
    }

    static func blocks(_ text: String) -> [Block] {
        text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { return nil }
            if line.hasPrefix("#") {
                return .heading(String(line.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces))
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                return .bullet("•", String(line.dropFirst(2)))
            }
            if let match = line.firstMatch(of: /^(\d{1,2}[.)])\s+(.*)$/) {
                return .bullet(String(match.1), String(match.2))
            }
            return .paragraph(line)
        }
    }

    static func inline(_ line: String) -> AttributedString {
        (try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(line)
    }
}

extension CourseMemory {
    /// For reading and editing only: never asks ChatGPT (nothing here builds the memory).
    static func viewer(_ database: UniDatabase) -> CourseMemory {
        CourseMemory(database: database, complete: { _, _ in throw CancellationError() }, model: "")
    }
}
