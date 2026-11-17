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
    /// Opens the course memory at a heading (nil: the memory as a whole).
    let openMemory: (String?) -> Void
    let close: () -> Void
    /// The submission rules row is expanded (internal so the debug screenshots can open it).
    @State var showsRules = false

    @State private var draft = ""
    @State private var exporting = false
    @State private var exportError: String?
    @State private var added: String?
    @State private var pickingFile = false
    @State private var settingUpHandwriting = false
    /// The not-read list is expanded (internal for the debug screenshots too).
    @State var showsUnread = false
    @FocusState private var chatFocused: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.signedIn {
                sheetBar
                Divider()
                if model.rulesError != nil && model.rules == nil && !model.needsSheet {
                    rulesFailedRow
                    Divider()
                } else if model.rules != nil && !model.needsSheet {
                    rulesRow
                    Divider()
                }
                if !model.unread.isEmpty {
                    unreadBanner
                    Divider()
                }
                // The PDF stays readable: an expanded section above takes the chat's room instead.
                preview.frame(minHeight: 320, maxHeight: .infinity)
                Divider()
                // The details form gets the room; nothing can be sent until it's saved.
                if !waitsForDetails && !showsRules && !showsUnread {
                    chat
                    Divider()
                }
                actions
            } else {
                signIn
            }
        }
        .background(Theme.paper)
        .task { model.start() }
        // However the panel goes away (closed, sheet dismissed), nothing keeps calling ChatGPT.
        .onDisappear { model.close() }
        .onChange(of: model.signedIn) { _, signedIn in if signedIn { model.start() } }
        // Back from Settings (or anywhere): details changed there reach this PDF.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            model.reloadStudent()
        }
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
            memoryProgress(memory)
        } else if model.phase == .rules {
            progress("Reading the submission rules…")
        } else if case .needsDetails(let fields) = model.phase {
            DetailsForm(model: model, fields: fields).id(fields)
        } else if case .reading(let message) = model.phase {
            progress(message)
        } else if !model.hasSolution && model.solution.isEmpty {
            if model.rulesError != nil && model.rules == nil && !model.isBusy {
                waitingForRules
            } else if case .failed(let message) = model.phase {
                failure("Couldn't Solve It", message) { Button("Try Again") { model.resolve() } }
            } else {
                progress("Solving…")
            }
        } else {
            switch model.format {
            case .typed:
                typed
            case .handwritten:
                handwritten
            }
        }
    }

    /// Streaming, the formatted solution; once a revision is done, the PDF that gets handed in.
    @ViewBuilder
    private var typed: some View {
        if model.phase == .writing || !model.hasSolution {
            SolutionWebView(markdown: model.solution, streaming: model.phase == .writing)
        } else if let output = model.output[.typed], output.revision == model.revision {
            PDFPreview(data: output.data)
        } else if let error = model.outputError {
            failure("Couldn't Make the PDF", error) { Button("Try Again") { model.makePreview() } }
        } else {
            SolutionWebView(markdown: model.solution, streaming: false)
                .overlay(alignment: .top) { makingPDF }
                .task(id: model.revision) { model.makePreview() }
        }
    }

    private var makingPDF: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Making the PDF…").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 10)
        .background(Capsule().fill(.regularMaterial))
        .padding(.top, 8)
    }

    /// The handwritten PDF, with the characters that had no glyph.
    @ViewBuilder
    private func handwrittenPDF(_ rendering: Handwriter.Rendering) -> some View {
        VStack(spacing: 0) {
            if !rendering.dropped.isEmpty {
                Label("Left out (no glyph): \(rendering.dropped.joined(separator: " "))", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Theme.dueSoon)
                    .padding(.top, 8)
            }
            if let output = model.output[.handwritten], output.revision == model.revision {
                PDFPreview(data: output.data)
            } else if let error = model.outputError {
                failure("Couldn't Make the PDF", error) { Button("Try Again") { model.makePreview() } }
            } else {
                progress("Making the PDF…").task(id: model.revision) { model.makePreview() }
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
                handwrittenPDF(rendering)
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

    /// Reading the course PDFs into the memory, file by file.
    private func memoryProgress(_ memory: CourseMemory.Progress) -> some View {
        VStack(spacing: 10) {
            if memory.total == 0 {
                ProgressView()
                Text("Reading the course…").font(.callout).foregroundStyle(.secondary)
            } else {
                ProgressView(value: Double(memory.done), total: Double(memory.total))
                    .frame(maxWidth: 260)
                Text("Reading the course: \(memory.done) of \(memory.total) \(memory.total == 1 ? "file" : "files")")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let current = memory.current {
                Text(current).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 360)
            }
            Button("Skip for Now") { model.skipMemory() }
                .help("Solve with what the course memory has so far")
                .padding(.top, 4)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    // MARK: Submission rules

    /// The rules call failed: Solve waits, the choices are in the rules row above.
    private var waitingForRules: some View {
        VStack(spacing: 10) {
            Image(systemName: "list.bullet.rectangle").font(.system(size: 28)).foregroundStyle(.secondary)
            Text("The solution is written once the submission rules are read.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// "Couldn't read the submission rules." with Retry (only the rules call) and Continue Without
    /// Rules, in the style of the not-read banner.
    private var rulesFailedRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.dueSoon)
            VStack(alignment: .leading, spacing: 1) {
                Text("Couldn't read the submission rules.")
                if let reason = model.rulesError, !reason.isEmpty {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            Button("Continue Without Rules") { model.continueWithoutRules() }
                .controlSize(.small)
                .disabled(model.isBusy)
                .help("Write the solution with only your name in the header")
            Button("Retry") { model.retryRules() }
                .controlSize(.small)
                .disabled(model.isBusy)
                .help("Read the sheet's submission rules again")
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    /// "Submission rules": the header fields and the file name; expanded, the values (editable for
    /// this PDF), the other rules and the sheet's own words.
    private var rulesRow: some View {
        let rules = model.activeRules
        let partner: Set<SubmissionRules.Field> = [.partnerNames, .partnerMatrikelnr]
        let fields = rules.header.filter { $0 != .sheet && !(model.courseDetails.alone && partner.contains($0)) }
        let dropped = SubmissionRules.droppable.filter(model.droppedFields.contains)
        let needsSheet = rules.filename?.lowercased().contains("{sheet}") == true
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    showsRules.toggle()
                    if showsRules { showsUnread = false }
                }
            } label: {
                HStack(spacing: 8) {
                    Text("Submission rules").foregroundStyle(.secondary)
                    Text(fields.map(rules.shortLabel).joined(separator: " · ") + " → " + model.suggestedFilename)
                        .lineLimit(1).truncationMode(.head)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showsRules ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(showsRules ? "Hide the submission rules" : "Show the submission rules and the header values")
            .accessibilityValue(showsRules ? "Expanded" : "Collapsed")
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            if showsRules {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                            ForEach(fields, id: \.self) { field in
                                GridRow {
                                    Text(rules.shortLabel(field)).foregroundStyle(.secondary)
                                        .gridColumnAlignment(.trailing)
                                    HStack(spacing: 4) {
                                        HeaderValueField(model: model, field: field, label: rules.shortLabel(field))
                                        Button { model.setNeeded(field, false) } label: { Image(systemName: "minus.circle") }
                                            .buttonStyle(.borderless)
                                            .help("Not needed for this sheet: leave \(rules.shortLabel(field)) out of this PDF's header and file name")
                                            .accessibilityLabel("\(rules.shortLabel(field)) not needed for this sheet")
                                    }
                                }
                            }
                            ForEach(dropped, id: \.self) { field in
                                GridRow {
                                    Text(rules.shortLabel(field)).foregroundStyle(.tertiary)
                                    HStack(spacing: 6) {
                                        Text("Not needed for this sheet").foregroundStyle(.secondary)
                                        Button("Add Back") { model.setNeeded(field, true) }
                                            .buttonStyle(.borderless)
                                            .controlSize(.small)
                                            .help("Put \(rules.shortLabel(field)) back into this PDF's header")
                                    }
                                }
                            }
                            if needsSheet {
                                GridRow {
                                    Text(rules.isGerman ? "Blatt-Nr." : "Sheet no.").foregroundStyle(.secondary)
                                    HeaderValueField(model: model, field: .sheet, label: rules.isGerman ? "Blatt-Nr." : "Sheet no.")
                                        .frame(maxWidth: 80, alignment: .leading)
                                }
                            }
                            GridRow {
                                Text(rules.isGerman ? "Dateiname" : "File name").foregroundStyle(.secondary)
                                Text(model.suggestedFilename).textSelection(.enabled)
                            }
                        }
                        Text("Changes here apply to this PDF only. Your saved details are in Settings.")
                            .font(.caption).foregroundStyle(.secondary)
                        if !rules.other.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(Array(rules.other.enumerated()), id: \.offset) { _, rule in
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Text("•").foregroundStyle(.secondary)
                                        Text(rule)
                                    }
                                }
                            }
                        }
                        if let quote = rules.quote, !quote.isEmpty {
                            Text("“\(quote)”").italic().foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                }
                .frame(maxHeight: 200)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
    }

    // MARK: Not read

    /// Course PDFs Solve couldn't read, with Retry.
    private var unreadBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        showsUnread.toggle()
                        if showsUnread { showsRules = false }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.dueSoon)
                        Text("\(model.unread.count) \(model.unread.count == 1 ? "file" : "files") not read")
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(showsUnread ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(showsUnread ? "Hide the files" : "Show which files and why")
                .accessibilityValue(showsUnread ? "Expanded" : "Collapsed")
                Spacer()
                Button("Retry") { model.retryMemory() }
                    .controlSize(.small)
                    .disabled(model.isBusy)
                    .help("Read these files again")
            }
            if showsUnread {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(model.unread.enumerated()), id: \.offset) { _, file in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(file.title).lineLimit(1).truncationMode(.middle)
                                Text(file.reason).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    // MARK: Sources

    private struct SourceChip: Identifiable {
        let id: String
        let title: String
        let systemImage: String
        let help: String
        let open: () -> Void
    }

    private var lastAssistant: UUID? { model.messages.last { $0.role == .assistant }?.id }

    /// What the solution drew on: excerpts open the PDF at the page, memory sections the course memory.
    private var sourceChips: [SourceChip] {
        var seen = Set<String>()
        return model.sources.compactMap { source in
            switch source {
            case .excerpt(let number):
                guard let excerpt = model.excerpts.first(where: { $0.number == number }) else { return nil }
                let id = "x\(excerpt.itemId):\(excerpt.page)"
                guard seen.insert(id).inserted else { return nil }
                return SourceChip(id: id, title: "\(excerpt.title) p. \(excerpt.page)", systemImage: "doc.text",
                                  help: "Open \(excerpt.title) at page \(excerpt.page)") {
                    openWindow(id: "viewer", value: ViewerTarget(itemId: excerpt.itemId, page: excerpt.page))
                }
            case .memory(let section):
                let id = "m" + section.lowercased()
                guard seen.insert(id).inserted else { return nil }
                return SourceChip(id: id, title: "Memory: \(section)", systemImage: "brain",
                                  help: "Show this part of the course memory") {
                    openMemory(model.memoryHeading(for: section))
                }
            }
        }
    }

    private var sourcesRow: some View {
        ChipFlow(spacing: 6) {
            ForEach(sourceChips) { chip in
                Button(action: chip.open) {
                    Label(chip.title, systemImage: chip.systemImage)
                        .lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(chip.help)
            }
        }
        .padding(.trailing, 40)
    }

    // MARK: Chat

    private var chat: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.messages) { message in
                            VStack(alignment: .leading, spacing: 6) {
                                bubble(message)
                                if message.id == lastAssistant, !sourceChips.isEmpty { sourcesRow }
                            }
                            .id(message.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: model.messages.last?.text) {
                    if let last = model.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .onChange(of: model.sources) {
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
                    .disabled(waitsForDetails)
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
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || waitsForDetails)
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

    /// Waiting for the details form: nothing can be sent until it's saved.
    private var waitsForDetails: Bool {
        if case .needsDetails = model.phase { true } else { false }
    }

    private func send() {
        guard !model.isBusy, !waitsForDetails else { return }
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
                        // The format of the PDF being attached, not whatever is shown once it's made.
                        let format = model.format
                        await export {
                            let attachment = try await model.attachment()
                            attach(attachment.filename, attachment.data)
                            added = "Added \(format == .handwritten ? "handwritten" : "typed") PDF"
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
            Text("Solve uses your ChatGPT plan (the same sign-in as Ask). The assignment's text and attached sheets are sent to OpenAI. Solve and the course memory send the course's PDF text to your ChatGPT plan, file by file.")
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

/// A header value in the rules row: edits are kept for this PDF only, committed on Return or when
/// the field loses focus (each commit makes the PDFs again). Cleared, it shows the saved value again.
private struct HeaderValueField: View {
    let model: SolveModel
    let field: SubmissionRules.Field
    let label: String
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(label, text: $text)
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { _, focused in if !focused { commit() } }
            .onChange(of: model.headerValue(field)) { _, value in if !focused { text = value } }
            .onAppear { text = model.headerValue(field) }
            // The file name needs a number.
            .onChange(of: text) { _, value in
                if field == .sheet, value.contains(where: { !$0.isASCII || !$0.isNumber }) {
                    text = value.filter { $0.isASCII && $0.isNumber }
                }
            }
    }

    private func commit() {
        if text.trimmingCharacters(in: .whitespacesAndNewlines) != model.headerValue(field) {
            model.overrideHeader(field, value: text)
        }
        text = model.headerValue(field)
    }
}

/// Lays out chips left to right, wrapping onto new lines.
private struct ChipFlow: Layout {
    var spacing: CGFloat = 6
    /// Longer chips are truncated.
    var maxItemWidth: CGFloat = 230

    private func size(_ subview: LayoutSubview, in width: CGFloat) -> CGSize {
        let ideal = subview.sizeThatFits(.unspecified)
        guard ideal.width > min(maxItemWidth, width) else { return ideal }
        return subview.sizeThatFits(ProposedViewSize(width: min(maxItemWidth, width), height: nil))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = size(subviews[index], in: bounds.width)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        for (index, subview) in subviews.enumerated() {
            let size = size(subview, in: width)
            if let last = rows.last, last.width + spacing + size.width <= width {
                rows[rows.count - 1].indices.append(index)
                rows[rows.count - 1].width += spacing + size.width
                rows[rows.count - 1].height = max(last.height, size.height)
            } else {
                rows.append(([index], size.width, size.height))
            }
        }
        return rows
    }
}
