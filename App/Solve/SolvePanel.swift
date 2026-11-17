import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UniversityKit

/// The side panel the Solve button opens next to the hand-in sheet: the solution (handwritten or
/// typed), a chat to ask for changes, and Add to Submission.
struct SolvePanel: View {
    @Bindable var model: SolveModel
    let ask: AskModel
    let acceptsFiles: Bool
    let acceptsText: Bool
    /// Adds the PDF to the submission's files.
    let attach: (String, Data) -> Void
    /// Puts the typed solution into the submission's online text.
    let useAsText: (String) -> Void
    let close: () -> Void

    @State private var draft = ""
    @State private var exporting = false
    @State private var exportError: String?
    @State private var added: String?
    @State private var pickingFile = false
    @State private var settingUpHandwriting = false
    @FocusState private var chatFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.signedIn {
                sheetBar
                Divider()
                preview.frame(maxHeight: .infinity)
                Divider()
                chat
                Divider()
                actions
            } else {
                signIn
            }
        }
        .background(Theme.paper)
        .task { model.start() }
        // However the panel goes away (closed, sheet dismissed), nothing keeps calling ChatGPT.
        .onDisappear { model.stop() }
        .onChange(of: model.signedIn) { _, signedIn in if signedIn { model.start() } }
        .sheet(isPresented: $settingUpHandwriting, onDismiss: { model.handwritingChanged() }) { HandwritingSetupView() }
        .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.pdf]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) { model.choose(.file(name: url.lastPathComponent, data: data)) }
        }
    }

    // MARK: Sheet

    /// Which exercise sheet the solution is for, and a menu to pick another.
    private var sheetBar: some View {
        HStack(spacing: 8) {
            Text("Sheet").foregroundStyle(.secondary)
            Menu {
                sheetChoices
            } label: {
                Label(model.sheet.name ?? (model.assignment.attachments.isEmpty ? "None chosen" : "Assignment attachments"),
                      systemImage: "doc.text")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("The exercise sheet to solve")
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var sheetChoices: some View {
        if !model.candidates.isEmpty {
            Section("Course materials") {
                ForEach(model.candidates.prefix(20)) { candidate in
                    Button {
                        model.choose(.material(candidate))
                    } label: {
                        if case .material(let chosen) = model.sheet, chosen.id == candidate.id {
                            Label(candidate.name, systemImage: "checkmark")
                        } else {
                            Text(candidate.name)
                        }
                    }
                }
            }
        }
        Button("Choose a PDF…") { pickingFile = true }
        Button("Only the assignment description") { model.choose(.none) }
    }

    /// No sheet found: ask which one before solving.
    private var chooseSheet: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.text.magnifyingglass").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("Which sheet should it solve?").font(.headline)
            Text("This assignment has no sheet attached, and no course material clearly matches “\(model.assignment.name)”.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if !model.candidates.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.candidates.prefix(12)) { candidate in
                            Button { model.choose(.material(candidate)) } label: {
                                HStack {
                                    FileIcon(filename: candidate.item.filename ?? candidate.name, size: 16)
                                    Text(candidate.name).lineLimit(1)
                                    Spacer()
                                    Text(candidate.item.course).font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 5).padding(.horizontal, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
            HStack {
                Button("Choose a PDF…") { pickingFile = true }
                Button("Use the Description Only") { model.choose(.none) }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Label("Solve", systemImage: "sparkles").font(.headline)
            Spacer()
            Picker("Format", selection: $model.format) {
                ForEach(SolveModel.Format.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Button { close() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Close the Solve panel")
                .keyboardShortcut("w", modifiers: [.command, .shift])
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
    }

    // MARK: Preview

    @ViewBuilder
    private var preview: some View {
        if model.needsSheet {
            chooseSheet
        } else if case .memory(let memory) = model.phase {
            VStack(spacing: 10) {
                progress(memory.total == 0 ? "Reading the course materials…"
                         : "Reading the course materials (\(memory.done) of \(memory.total))…\(memory.current.map { "\n\($0)" } ?? "")")
                Button("Skip for Now") { model.skipMemory() }
            }
        } else if model.phase == .rules {
            progress("Reading the submission rules…")
        } else if case .needsDetails(let fields) = model.phase {
            failure("Details Needed", "The sheet asks for: \(fields.map(\.rawValue).joined(separator: ", ")).") {
                Button("Continue") { model.saveDetails(student: model.student, course: model.courseDetails) }
            }
        } else if case .reading(let message) = model.phase {
            progress(message)
        } else if !model.hasSolution && model.solution.isEmpty {
            if case .failed(let message) = model.phase {
                failure("Couldn't Solve It", message) { Button("Try Again") { model.resolve() } }
            } else {
                progress("Solving…")
            }
        } else {
            switch model.format {
            case .typed:
                SolutionWebView(markdown: model.solution, streaming: model.phase == .writing)
            case .handwritten:
                handwritten
            }
        }
    }

    @ViewBuilder
    private var handwritten: some View {
        if model.phase == .writing {
            progress("Writing the solution… It's turned into handwriting when it's done.")
        } else {
            switch model.handwriting {
            case .ready(let rendering, let revision) where revision == model.revision:
                HandwrittenPages(rendering: rendering)
            case .notSetUp:
                failure("Set Up Your Handwriting",
                        "Fill in a two-page template by hand and upload a photo or scan of it. Your handwriting stays on this Mac.") {
                    Button("Set Up My Handwriting…") { settingUpHandwriting = true }
                }
            case .failed(let message):
                failure("Couldn't Write It by Hand", message) { Button("Try Again") { model.renderHandwritingIfNeeded() } }
            case .converting:
                progress("Turning the solution into Math Writer notation…")
            case .rendering, .ready, .none:
                progress("Writing it in your handwriting…")
                    .task { model.renderHandwritingIfNeeded() }
            }
        }
    }

    private func progress(_ message: String) -> some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failure(_ title: String, _ message: String, @ViewBuilder actions: () -> some View) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            actions()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Chat

    private var chat: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.messages) { message in
                            bubble(message).id(message.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: model.messages.last?.text) {
                    if let last = model.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .frame(height: 150)

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask for a change, e.g. “show more steps in 2(b)”", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .focused($chatFocused)
                    .onSubmit(send)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
                if model.isBusy {
                    Button { model.stop() } label: { Image(systemName: "stop.circle.fill").font(.title2) }
                        .buttonStyle(.borderless)
                        .help("Stop")
                } else {
                    Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .buttonStyle(.borderless)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                        .help("Send")
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
    }

    private func bubble(_ message: SolveModel.Message) -> some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            Group {
                if message.role == .assistant && message.text.isEmpty {
                    ProgressView().controlSize(.small)
                } else {
                    Text(message.text).textSelection(.enabled)
                }
            }
            .font(.callout)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .foregroundStyle(message.role == .user ? Color.white : message.failed ? Theme.overdue : Color.primary)
            .background(RoundedRectangle(cornerRadius: 10).fill(message.role == .user ? Color.accentColor : Color.secondary.opacity(0.12)))
            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }

    private func send() {
        guard !model.isBusy else { return }
        model.send(draft)
        draft = ""
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 8) {
            Button { model.resolve() } label: { Image(systemName: "arrow.clockwise") }
                .help("Solve again from scratch")
                .disabled(model.isBusy)
            Button("Open PDF") { Task { await export { try await model.openPDF() } } }
                .disabled(!model.canExport || exporting)
            Spacer()
            if exporting {
                ProgressView().controlSize(.small)
            } else if let exportError {
                Text(exportError).font(.caption).foregroundStyle(Theme.overdue).lineLimit(2)
            } else if let added {
                Label(added, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(Theme.done)
            }
            if acceptsText && (!acceptsFiles || model.format == .typed) {
                Button("Use as Text") {
                    useAsText(model.solution)
                    added = "In Online Text"
                }
                .disabled(!model.hasSolution || model.isBusy)
            }
            if acceptsFiles {
                Button("Add to Submission") {
                    Task {
                        await export {
                            attach(model.suggestedFilename, try await model.pdf())
                            added = "Added \(model.format == .handwritten ? "handwritten" : "typed") PDF"
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canExport || exporting)
            }
        }
        .controlSize(.regular)
        .padding(12)
    }

    private func export(_ work: () async throws -> Void) async {
        exporting = true
        exportError = nil
        added = nil
        defer { exporting = false }
        do { try await work() } catch {
            exportError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: Sign-in

    private var signIn: some View {
        ContentUnavailableView {
            Label("Continue with ChatGPT", systemImage: "sparkles")
        } description: {
            Text("Solve uses your ChatGPT plan (the same sign-in as Ask). The assignment's text and attached sheets are sent to OpenAI.")
        } actions: {
            if ask.account == nil {
                Button("Continue with ChatGPT") { Task { await ask.signIn() } }
                    .disabled(ask.isSigningIn)
            } else {
                Text("Choose a model in Settings → ChatGPT.").foregroundStyle(.secondary)
            }
            if let error = ask.signInError { Text(error).font(.caption).foregroundStyle(Theme.overdue) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Math Writer's pages, one under the other.
private struct HandwrittenPages: View {
    let rendering: Handwriter.Rendering
    @State private var images: [NSImage] = []

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if !rendering.dropped.isEmpty {
                    Label("Left out (no glyph): \(rendering.dropped.joined(separator: " "))", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(Theme.dueSoon)
                }
                ForEach(images.indices, id: \.self) { index in
                    Image(nsImage: images[index])
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                }
            }
            .padding(14)
        }
        .task(id: rendering) {
            images = rendering.pages.compactMap { NSImage(contentsOf: $0) }
        }
    }
}
