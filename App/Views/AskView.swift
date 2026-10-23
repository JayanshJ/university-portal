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
            PageHeader("Ask your materials", subtitle: subtitle) {
                if !ask.turns.isEmpty {
                    Button("New conversation") { ask.clear() }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
            }

            if !signedInForPlan {
                ScrollView { SignInCard(ask: ask).padding(.horizontal, Theme.gutter) }
            } else if ask.indexStatus.indexed == 0 {
                ScrollView { IndexCard(ask: ask, first: true).padding(.horizontal, Theme.gutter) }
            } else {
                FilterBar(courseIds: courseIds, selection: $ask.courseFilter)
                    .padding(.horizontal, Theme.gutter).padding(.bottom, 10)
                conversation
                Composer(ask: ask, draft: $draft)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(isPresented: $ask.showWelcome) { WelcomeSheet(ask: ask) }
        .onAppear { ask.indexNewMaterialsIfIndexedBefore() }
    }

    private var subtitle: String {
        let status = ask.indexStatus
        guard status.total > 0 else { return "Answers from your lecture PDFs, with page references" }
        return "\(status.indexed) of \(status.total) PDFs indexed · \(status.pages) pages · answers cite the page"
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
                IndexCard(ask: ask, first: false)
                    .padding(.horizontal, Theme.gutter).padding(.bottom, 8)
                    .frame(maxWidth: 860 + 2 * Theme.gutter)
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

private struct SignInCard: View {
    let ask: AskModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "sparkles").font(.system(size: 26)).foregroundStyle(Theme.accent)
            Text("Ask questions about your lecture PDFs")
                .font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.text)
            VStack(alignment: .leading, spacing: 8) {
                bullet("text.magnifyingglass", "Finds the right pages in your Moodle and CMS PDFs, in English or German.")
                bullet("quote.bubble", "Answers cite each source; click a citation to open the PDF at that page.")
                bullet("person.crop.circle.badge.checkmark", "Runs on your ChatGPT Plus or Pro plan. No API key, no extra cost.")
                bullet("lock", "Your PDFs are indexed on this Mac. Only your question and the matching excerpts are sent to OpenAI, and not stored there.")
            }
            HStack(spacing: 12) {
                Button {
                    Task { await ask.signIn() }
                } label: {
                    Text(ask.isSigningIn ? "Finish in your browser…" : "Continue with ChatGPT")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Capsule().fill(Color.white))
                }
                .buttonStyle(.plain)
                .disabled(ask.isSigningIn)
                if ask.isSigningIn { ProgressView().controlSize(.small) }
            }
            .padding(.top, 4)
            if let error = ask.signInError {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.overdue)
            }
        }
        .padding(24)
        .frame(maxWidth: 620, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.corner).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(Theme.border))
        .padding(.top, 8)
    }

    private func bullet(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon).frame(width: 18).foregroundStyle(Theme.secondary)
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.secondary)
        }
    }
}

private struct IndexCard: View {
    let ask: AskModel
    let first: Bool

    var body: some View {
        let progress = ask.indexProgress
        VStack(alignment: .leading, spacing: 10) {
            if progress.isRunning {
                HStack {
                    Text("Indexing \(min(progress.done + 1, progress.total)) of \(progress.total)")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                    Spacer()
                    if progress.failed > 0 {
                        Text("\(progress.failed) skipped").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                    }
                }
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))).tint(Theme.accent)
                if let current = progress.current {
                    Text(current).font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1)
                }
            } else {
                Text(first ? "Index your PDFs first" : "\(ask.pending.count) new PDF\(ask.pending.count == 1 ? "" : "s") to index")
                    .font(.system(size: first ? 17 : 13, weight: .semibold)).foregroundStyle(Theme.text)
                Text(first
                     ? "University Portal reads the text of your \(ask.pending.count) lecture PDFs on this Mac, so it can find the right pages. \(download)"
                     : "New materials arrived since the last index. \(download)")
                    .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                Button(first ? "Index now" : "Index") { ask.indexNow() }
                    .disabled(ask.pending.count == 0)
            }
        }
        .padding(first ? 24 : 14)
        .frame(maxWidth: first ? 620 : .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.corner).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(Theme.border))
        .padding(.top, first ? 8 : 0)
    }

    private var download: String {
        ask.pending.downloadBytes > 0
            ? "This downloads about \(ask.pending.downloadBytes.fileSizeText) once."
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

private struct Composer: View {
    @Bindable var ask: AskModel
    @Binding var draft: String
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Ask about your lecture materials…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .lineLimit(1...6)
                    .focused($focused)
                    .onSubmit(send)
                if ask.isAnswering {
                    Button { ask.stop() } label: { Image(systemName: "stop.circle.fill").font(.system(size: 22)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.secondary).help("Stop")
                } else {
                    Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 22)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(draft.trimmingCharacters(in: .whitespaces).isEmpty ? Theme.tertiary : Theme.accent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("Send (⌘↩)")
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(focused ? Theme.accent.opacity(0.5) : Theme.border))

            HStack(spacing: 10) {
                Menu {
                    ForEach(ask.models) { model in
                        Button { ask.setModel(model.slug) } label: {
                            if model.slug == ask.model { Label(model.displayName, systemImage: "checkmark") } else { Text(model.displayName) }
                        }
                    }
                } label: {
                    Text(ask.models.first { $0.slug == ask.model }?.displayName ?? ask.model ?? "Model")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .font(.system(size: 12))
                Text("Using ChatGPT plan").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                Link("Manage usage", destination: AskModel.manageUsageURL).font(.system(size: 12))
                Spacer()
                if ask.courseFilter != nil {
                    Text("Searching one course").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                }
            }
            .padding(.horizontal, 4)
        }
        .padding(.horizontal, Theme.gutter).padding(.vertical, 14)
        .frame(maxWidth: 860 + 2 * Theme.gutter)
        .frame(maxWidth: .infinity)
        .background(Theme.canvas)
        .onAppear { focused = true }
    }

    private func send() {
        guard !ask.isAnswering else { return }
        let question = draft
        draft = ""
        ask.ask(question)
    }
}
