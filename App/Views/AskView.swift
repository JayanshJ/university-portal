import SwiftUI
import UniversityKit

/// "Ask your materials": questions answered from your lecture PDFs on your ChatGPT plan, with
/// citations that open the PDF at the cited page.
struct AskView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let ask = app.ask {
            AskScreen(ask: ask)
        } else {
            EmptyState(title: "Ask is unavailable", systemImage: "sparkles", message: "The database could not be opened.")
        }
    }
}

private struct AskScreen: View {
    @Bindable var ask: AskModel
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @State private var draft = ""

    private var signedInForPlan: Bool { ask.account?.canUsePlan == true }

    var body: some View {
        VStack(spacing: 0) {
            if !signedInForPlan {
                SignInView(ask: ask)
            } else if ask.indexStatus.indexed == 0 {
                IndexView(ask: ask)
            } else {
                conversation
                Composer(ask: ask, draft: $draft)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.paper)
        .navigationTitle("Ask")
        .navigationSubtitle(subtitle)
        .toolbar {
            if signedInForPlan && ask.indexStatus.indexed > 0 {
                ToolbarItem { CoursePicker(courseIds: courseIds, selection: $ask.courseFilter) }
                ToolbarItem {
                    Button { ask.clear() } label: { Label("New Conversation", systemImage: "square.and.pencil") }
                        .help("New Conversation")
                        .disabled(ask.turns.isEmpty)
                }
            }
        }
        .sheet(isPresented: $ask.showWelcome) { WelcomeSheet(ask: ask) }
        .onAppear { ask.indexNewMaterialsIfIndexedBefore() }
    }

    private var subtitle: String {
        let status = ask.indexStatus
        guard status.total > 0 else { return "Answers from your lecture PDFs" }
        return "\(status.indexed) of \(status.total) PDFs indexed · \(status.pages) pages"
    }

    /// Courses that have indexed PDFs.
    private var courseIds: [Int64] {
        var seen = Set<Int64>()
        return app.overview.materials.filter { ($0.filename ?? "").lowercased().hasSuffix(".pdf") }
            .compactMap { seen.insert($0.courseId).inserted ? $0.courseId : nil }
    }

    /// Starting points shown before the first question, in StudyGPT's style.
    private var suggestions: [String] {
        let names = courseIds.prefix(3).map { app.overview.style(for: $0).name }
        var prompts = names.prefix(2).map { "Summarise the key ideas of the latest \($0) lecture" }
        if let first = names.first { prompts.append("Make flashcards for \(first)") }
        return prompts + ["What should I revise for my next exam?", "Explain the hardest concept from this week, with an example"]
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            if ask.pending.count > 0 || ask.indexProgress.isRunning {
                IndexBar(ask: ask)
                Divider()
            }
            ChatTranscript(
                turns: ask.turns,
                model: ask.models.first { $0.slug == ask.model }?.displayName ?? ask.model,
                suggestions: suggestions,
                courseColor: { app.overview.style(for: $0).color.hex },
                onCite: { excerpt in
                    openWindow(id: "viewer", value: ViewerTarget(itemId: excerpt.itemId, page: excerpt.page))
                },
                onSuggest: { draft = $0 },
                onRegenerate: { ask.regenerate($0) })
        }
    }
}

// MARK: - Sign-in and indexing

private struct SignInView: View {
    let ask: AskModel

    var body: some View {
        ContentUnavailableView {
            Label("Ask Your Lecture Materials", systemImage: "sparkles")
        } description: {
            VStack(spacing: 10) {
                Text("Answers come from your Moodle and CMS PDFs, in English or German, and cite the page they're from. Click a citation to open the PDF there.")
                Text("Runs on your ChatGPT Plus or Pro plan, with no API key. Your PDFs are indexed on this Mac; only your question and the matching excerpts are sent to OpenAI, and they aren't stored there.")
                    .font(.callout)
            }
        } actions: {
            Button(ask.isSigningIn ? "Finish in Your Browser…" : "Continue with ChatGPT") {
                Task { await ask.signIn() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(ask.isSigningIn)
            if let error = ask.signInError {
                Text(error).font(.callout).foregroundStyle(Theme.overdue).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct IndexView: View {
    let ask: AskModel

    var body: some View {
        let progress = ask.indexProgress
        ContentUnavailableView {
            Label(progress.isRunning ? "Indexing Your PDFs" : "Index Your PDFs First", systemImage: "doc.text.magnifyingglass")
        } description: {
            if progress.isRunning {
                VStack(spacing: 8) {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    Text("\(min(progress.done + 1, progress.total)) of \(progress.total)\(progress.current.map { ": \($0)" } ?? "")")
                        .font(.callout).lineLimit(1)
                }
                .frame(width: 320)
            } else {
                Text("University Portal reads the text of your \(ask.pending.count) lecture PDFs on this Mac, so it can find the right pages. \(ask.downloadNote)")
            }
        } actions: {
            if !progress.isRunning {
                Button("Index Now") { ask.indexNow() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(ask.pending.count == 0)
            }
        }
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// New materials waiting to be indexed, or indexing in progress, above the conversation.
private struct IndexBar: View {
    let ask: AskModel

    var body: some View {
        let progress = ask.indexProgress
        HStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass").foregroundStyle(.secondary)
            if progress.isRunning {
                Text("Indexing \(min(progress.done + 1, progress.total)) of \(progress.total)")
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))).frame(maxWidth: 220)
                Spacer()
                if progress.failed > 0 { Text("\(progress.failed) skipped").foregroundStyle(.secondary) }
            } else {
                Text("\(ask.pending.count) new PDF\(ask.pending.count == 1 ? "" : "s") to index. \(ask.downloadNote)")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Index") { ask.indexNow() }
            }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

extension AskModel {
    var downloadNote: String {
        pending.downloadBytes > 0
            ? "This downloads about \(pending.downloadBytes.fileSizeText) once."
            : "The files are already on this Mac."
    }
}

private struct WelcomeSheet: View {
    let ask: AskModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("You're using your ChatGPT plan").font(.system(size: 18, weight: .semibold))
            Text("Questions you ask in University Portal use your ChatGPT plan. You can see and manage this app's usage in ChatGPT settings.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Link("Manage usage", destination: AskModel.manageUsageURL)
                Spacer()
                Button("Got it") { ask.showWelcome = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}

/// The message field at the bottom, like Messages, with the model and plan underneath.
private struct Composer: View {
    @Bindable var ask: AskModel
    @Binding var draft: String
    @FocusState private var focused: Bool

    private var isEmpty: Bool { draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask about your lecture materials", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .focused($focused)
                    .onSubmit(send)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Theme.paper))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator))
                if ask.isAnswering {
                    Button { ask.stop() } label: { Image(systemName: "stop.circle.fill").font(.title) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Stop")
                } else {
                    Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title) }
                        .buttonStyle(.plain)
                        .foregroundStyle(isEmpty ? Color.secondary : Color.accentColor)
                        .disabled(isEmpty)
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("Send (⌘↩)")
                }
            }
            HStack(spacing: 6) {
                Picker("Model", selection: Binding(get: { ask.model }, set: { ask.setModel($0) })) {
                    ForEach(ask.models) { Text($0.displayName).tag(String?.some($0.slug)) }
                }
                .pickerStyle(.menu)
                .buttonStyle(.borderless)
                .labelsHidden()
                .fixedSize()
                Text("·")
                Text("Using ChatGPT plan")
                Link("Manage usage", destination: AskModel.manageUsageURL)
                Spacer()
                if ask.courseFilter != nil { Text("Searching one course") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .onAppear { focused = true }
    }

    private func send() {
        guard !ask.isAnswering else { return }
        let question = draft
        draft = ""
        ask.ask(question)
    }
}
