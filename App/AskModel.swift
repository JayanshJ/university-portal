import AppKit
import Foundation
import UniversityKit

/// One question and its answer in the Ask conversation.
struct AskTurn: Identifiable, Equatable {
    enum Phase: Equatable {
        case searching, writing, done
        case failed(String)
    }

    let id = UUID()
    var question: String
    var courseId: Int64?
    var answer = ""
    var excerpts: [Excerpt] = []
    var phase: Phase = .searching

    var cited: [Int] { AskService.citations(in: answer) }
}

/// State and actions of "Ask your materials": the ChatGPT sign-in, the model, the page index and the conversation.
@MainActor @Observable
final class AskModel {
    struct Account: Equatable {
        var email: String?
        var canUsePlan: Bool
    }

    private(set) var account: Account?
    private(set) var isSigningIn = false
    var signInError: String?
    private(set) var models: [ChatGPTModel] = []
    private(set) var model: String?
    var showWelcome = false

    private(set) var indexStatus = MaterialIndexer.Status(indexed: 0, total: 0, pages: 0)
    private(set) var pending: (count: Int, downloadBytes: Int64) = (0, 0)
    private(set) var indexProgress = MaterialIndexer.Progress()

    private(set) var turns: [AskTurn] = []
    var courseFilter: Int64?
    var isAnswering: Bool { turns.last.map { $0.phase == .searching || $0.phase == .writing } ?? false }

    @ObservationIgnored private let database: UniDatabase
    @ObservationIgnored private let auth: ChatGPTAuth
    @ObservationIgnored private let client: ResponsesClient
    @ObservationIgnored private let service: AskService
    @ObservationIgnored private let indexer: MaterialIndexer
    @ObservationIgnored private var answering: Task<Void, Never>?
    @ObservationIgnored private var indexing: Task<Void, Never>?
    @ObservationIgnored private let textSchedule: TextSchedule
    @ObservationIgnored private var readingDates: Task<Void, Never>?

    private static let log = Log(category: "ask")
    static let manageUsageURL = URL(string: "https://chatgpt.com/settings/usage")!

    init(database: UniDatabase, secrets: any SecretStore, transport: any HTTPTransport, files: MaterialFiles) {
        self.database = database
        auth = ChatGPTAuth(secrets: secrets, transport: transport, openBrowser: { url in
            Task { @MainActor in NSWorkspace.shared.open(url) }
        })
        client = ResponsesClient(auth: auth, transport: transport, streaming: URLSessionStreamingTransport())
        service = AskService(retriever: Retriever(database: database), client: client)
        indexer = MaterialIndexer(database: database, files: files)
        textSchedule = TextSchedule(database: database, client: client)
        model = try? database.state(.chatgptModel, as: String.self)
        Task {
            await refreshAccount()
            if account?.canUsePlan == true {
                await loadModels()
                readCourseDates()
            }
        }
        refreshIndexStatus()
    }

    // MARK: - ChatGPT

    func refreshAccount() async {
        account = await auth.credentials().map { Account(email: $0.email, canUsePlan: $0.canUsePlan) }
    }

    func signIn() async {
        guard !isSigningIn else { return }
        isSigningIn = true
        signInError = nil
        defer { isSigningIn = false }
        do {
            let credentials = try await auth.signIn()
            account = Account(email: credentials.email, canUsePlan: credentials.canUsePlan)
            NSApp.activate()
            if credentials.canUsePlan {
                await loadModels()
                if (try? database.state(.chatgptWelcomeShown, as: Bool.self)) != true {
                    showWelcome = true
                    try? database.setState(.chatgptWelcomeShown, to: true)
                }
            } else {
                signInError = "Signed in, but plan usage wasn't allowed. Sign in again and allow University Portal to use your ChatGPT plan."
            }
        } catch {
            signInError = Self.describe(error)
        }
    }

    func signOut() async {
        let confirmed = await auth.signOut()
        account = nil
        models = []
        if !confirmed {
            signInError = "Signed out here. OpenAI didn't confirm the revocation; you can also disconnect University Portal in ChatGPT settings."
        }
    }

    func loadModels() async {
        do {
            models = try await client.models()
            if model == nil || !models.contains(where: { $0.slug == model }) { setModel(models.first?.slug) }
        } catch {
            Self.log.warning("Could not list ChatGPT models: \(error)")
            if case ChatGPTError.signInExpired = error { await refreshAccount() }
        }
    }

    func setModel(_ slug: String?) {
        model = slug
        if let slug { try? database.setState(.chatgptModel, to: slug) }
    }

    // MARK: - Dates in course texts

    /// Reads sessions, exams and presentations that Moodle courses only state in words (course
    /// page text, announcements) into the calendar. Courses whose text didn't change are skipped.
    /// A few seconds' delay lets a sync's changes settle first.
    func readCourseDates(after delay: Duration = .seconds(5)) {
        guard account?.canUsePlan == true, let model else { return }
        readingDates?.cancel()
        readingDates = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            do {
                let read = try await textSchedule.run(model: model)
                if read > 0 { Self.log.info("Read dates from \(read) courses") }
            } catch {
                Self.log.warning("Reading course dates failed: \(Redactor.redact(String(describing: error)))")
            }
        }
    }

    // MARK: - Index

    func refreshIndexStatus() {
        if let status = try? indexer.status() { indexStatus = status }
        if let pending = try? indexer.pendingSummary() { self.pending = pending }
    }

    func indexNow() {
        guard indexing == nil else { return }
        indexing = Task {
            await indexer.run { progress in
                Task { @MainActor in self.indexProgress = progress }
            }
            indexing = nil
            refreshIndexStatus()
        }
    }

    /// After the first full index, new materials are indexed automatically when Ask opens.
    func indexNewMaterialsIfIndexedBefore() {
        refreshIndexStatus()
        if indexStatus.indexed > 0, pending.count > 0 { indexNow() }
    }

    // MARK: - Asking

    func ask(_ question: String) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isAnswering, let model else { return }
        let history = turns.filter { $0.phase == .done }.suffix(3).flatMap {
            [ChatMessage(role: .user, content: $0.question), ChatMessage(role: .assistant, content: $0.answer)]
        }
        turns.append(AskTurn(question: question, courseId: courseFilter))
        let index = turns.count - 1
        let courseId = courseFilter

        answering = Task {
            do {
                let excerpts = try await service.excerpts(for: question, history: history, courseId: courseId, model: model)
                turns[index].excerpts = excerpts
                turns[index].phase = .writing
                for try await delta in service.answer(question: question, excerpts: excerpts, history: history, model: model) {
                    turns[index].answer += delta
                }
                turns[index].phase = .done
            } catch is CancellationError {
                turns[index].phase = turns[index].answer.isEmpty ? .failed("Stopped.") : .done
            } catch {
                turns[index].phase = .failed(Self.describe(error))
                if case ChatGPTError.signInExpired = error { await refreshAccount() }
            }
        }
    }

    /// Asks the last question again (StudyGPT's "regen").
    func regenerate(_ id: UUID) {
        guard !isAnswering, let index = turns.firstIndex(where: { $0.id == id }), index == turns.count - 1 else { return }
        let turn = turns.remove(at: index)
        let filter = courseFilter
        courseFilter = turn.courseId
        ask(turn.question)
        courseFilter = filter
    }

    func stop() {
        answering?.cancel()
    }

    /// Screenshot runs only: a signed-in look with a sample answer, no Keychain and no network.
    func showDemo(courseId: Int64?) {
        account = Account(email: "demo", canUsePlan: true)
        models = [ChatGPTModel(slug: "demo", displayName: "GPT-6.1 Sol")]
        model = "demo"
        if indexStatus.indexed == 0 { indexStatus = MaterialIndexer.Status(indexed: 30, total: 30, pages: 1_593) }
        pending = (0, 0)
        var turn = AskTurn(question: "Explain tail recursion with the examples from Programming 1", courseId: nil)
        turn.answer = Self.demoAnswer
        turn.excerpts = [
            Excerpt(number: 1, itemId: -1, courseId: courseId ?? 0, title: "A Getting Started.pdf", course: "Programming 1", page: 8,
                    text: "Tail-Recursive Version of pow: pow (x, n) = x * pow (x, n - 1) …"),
            Excerpt(number: 2, itemId: -2, courseId: courseId ?? 0, title: "Lecture Notes.pdf", course: "Programming 1", page: 282,
                    text: "Conversely, the application of a tail-recursive function can also be implemented as a loop …"),
        ]
        turn.phase = .done
        turns = [turn]
    }

    static let demoAnswer = """
        ## Tail recursion

        A function is **tail-recursive** when the recursive call is its *last* step, so nothing is pending afterwards [2]. \
        Programming 1 contrasts `pow` with an accumulator version [1].

        The naive version needs $n$ nested calls:

        $$
        \\text{pow}(x, n) = x \\cdot \\text{pow}(x, n-1), \\qquad \\text{pow}(x, 0) = 1
        $$

        | Version | Stack depth |
        |---|---|
        | naive | $O(n)$ |
        | tail-recursive | $O(1)$ |

        ```sml
        fun pow (x, 0, a) = a
          | pow (x, n, a) = pow (x, n - 1, a * x)
        ```

        > A tail call can be compiled into a jump [2].
        """

    func clear() {
        stop()
        turns = []
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case ChatGPTError.usageLimitReached:
            "You've reached the usage limit for University Portal on your ChatGPT plan. You can check or raise it under Manage usage."
        case ChatGPTError.notEligible:
            "Your ChatGPT plan can't be used in other apps. Plan usage needs ChatGPT Plus or Pro."
        case ChatGPTError.usageUnavailable:
            "ChatGPT plan usage is temporarily unavailable. Try again in a moment."
        case ChatGPTError.signInExpired, ChatGPTError.notSignedIn:
            "Your ChatGPT sign-in has expired. Continue with ChatGPT again."
        case ChatGPTError.planUsageNotGranted:
            "Plan usage wasn't allowed when you signed in. Sign in again and allow it."
        case ChatGPTError.accessDenied:
            "Sign-in was cancelled."
        case ChatGPTError.incomplete(let reason):
            "The answer was cut off (\(reason)). Try asking again."
        case ChatGPTError.server(let detail):
            "ChatGPT returned an error: \(detail)"
        case let error as URLError where error.code == .notConnectedToInternet:
            "You're offline."
        default:
            Redactor.redact(String(describing: error))
        }
    }
}
