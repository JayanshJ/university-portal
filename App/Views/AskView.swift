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

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if ask.pending.count > 0 || ask.indexProgress.isRunning {
                        IndexCard(ask: ask, first: false)
                    }
                    if ask.turns.isEmpty {
                        Suggestions(courseIds: courseIds) { draft = $0 }
                    }
                    ForEach(ask.turns) { turn in
                        TurnView(turn: turn) { excerpt in
                            openWindow(id: "viewer", value: ViewerTarget(itemId: excerpt.itemId, page: excerpt.page))
                        }
                        .id(turn.id)
                    }
                }
                .padding(.horizontal, Theme.gutter).padding(.bottom, 16)
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: ask.turns.last?.answer) {
                if let last = ask.turns.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onChange(of: ask.turns.count) {
                if let last = ask.turns.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
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

// MARK: - Conversation

private struct Suggestions: View {
    @Environment(AppModel.self) private var app
    let courseIds: [Int64]
    let pick: (String) -> Void

    var body: some View {
        let names = courseIds.prefix(3).map { app.overview.style(for: $0).name }
        let prompts = names.map { "Summarise the key ideas of the latest \($0) lecture" }
            + ["What should I revise for my next exam?", "Explain the hardest concept from this week's slides"]
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Try asking")
            ForEach(prompts, id: \.self) { prompt in
                Button { pick(prompt) } label: {
                    HStack {
                        Image(systemName: "arrow.up.right").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                        Text(prompt).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .rowBackground()
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 8)
    }
}

private struct TurnView: View {
    @Environment(AppModel.self) private var app
    let turn: AskTurn
    let open: (Excerpt) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer(minLength: 80)
                Text(turn.question)
                    .font(.system(size: 13)).foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Theme.raised))
            }

            VStack(alignment: .leading, spacing: 12) {
                switch turn.phase {
                case .searching:
                    status("Searching your materials…")
                case .writing where turn.answer.isEmpty:
                    status("Reading \(turn.excerpts.count) passages…")
                case .failed(let message):
                    if !turn.answer.isEmpty { AnswerText(text: turn.answer, excerpts: turn.excerpts, open: open) }
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12)).foregroundStyle(Theme.overdue)
                    if message.contains("usage limit") { Link("Manage usage", destination: AskModel.manageUsageURL).font(.system(size: 12)) }
                default:
                    AnswerText(text: turn.answer, excerpts: turn.excerpts, open: open)
                }
                if !turn.excerpts.isEmpty, turn.phase != .searching {
                    Sources(excerpts: turn.excerpts, cited: turn.cited, open: open)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.corner).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(Theme.border))
        }
    }

    private func status(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.secondary)
        }
    }
}

/// The answer with its "[2]" citations turned into links that open the cited page.
private struct AnswerText: View {
    let text: String
    let excerpts: [Excerpt]
    let open: (Excerpt) -> Void

    var body: some View {
        Text(Self.attributed(text))
            .font(.system(size: 14))
            .lineSpacing(4)
            .foregroundStyle(Theme.text)
            .tint(Theme.accent)
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "uportal-cite", let number = Int(url.host() ?? ""),
                      let excerpt = excerpts.first(where: { $0.number == number }) else { return .systemAction }
                open(excerpt)
                return .handled
            })
    }

    static func attributed(_ text: String) -> AttributedString {
        let pattern = try! NSRegularExpression(pattern: #"\[(\d+(?:\s*,\s*\d+)*)\]"#)
        let range = NSRange(text.startIndex..., in: text)
        var linked = ""
        var last = text.startIndex
        for match in pattern.matches(in: text, range: range) {
            guard let whole = Range(match.range, in: text), let inner = Range(match.range(at: 1), in: text) else { continue }
            linked += text[last..<whole.lowerBound]
            linked += text[inner].split(separator: ",").map { number in
                let n = number.trimmingCharacters(in: .whitespaces)
                return "[\\[\(n)\\]](uportal-cite://\(n))"
            }.joined()
            last = whole.upperBound
        }
        linked += text[last...]
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: linked, options: options)) ?? AttributedString(text)
    }
}

private struct Sources: View {
    @Environment(AppModel.self) private var app
    let excerpts: [Excerpt]
    let cited: [Int]
    let open: (Excerpt) -> Void

    var body: some View {
        // Cited sources first; uncited ones (if any were cited at all) are dimmed.
        let ordered = excerpts.filter { cited.contains($0.number) } + excerpts.filter { !cited.contains($0.number) }
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Sources")
            FlowLayout(spacing: 6) {
                ForEach(ordered) { excerpt in
                    let isCited = cited.isEmpty || cited.contains(excerpt.number)
                    let style = app.overview.style(for: excerpt.courseId)
                    Button { open(excerpt) } label: {
                        HStack(spacing: 6) {
                            Text("\(excerpt.number)").font(.system(size: 10, weight: .bold).monospacedDigit())
                                .foregroundStyle(Theme.canvas)
                                .frame(width: 16, height: 16)
                                .background(Circle().fill(isCited ? style.color : Theme.tertiary))
                            Text("\(Self.shortTitle(excerpt.title)) · p. \(excerpt.page)")
                                .font(.system(size: 12)).foregroundStyle(isCited ? Theme.text : Theme.tertiary)
                                .lineLimit(1)
                        }
                        .padding(.leading, 4).padding(.trailing, 10).padding(.vertical, 4)
                        .background(Capsule().fill(Theme.raised))
                    }
                    .buttonStyle(.plain)
                    .help("\(style.name) — \(excerpt.title), page \(excerpt.page)\n\n\(excerpt.text.prefix(240))…")
                }
            }
        }
    }

    static func shortTitle(_ title: String) -> String {
        let name = (title as NSString).deletingPathExtension
        return name.count > 38 ? String(name.prefix(36)) + "…" : name
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

/// Wraps its children onto new lines when they don't fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
