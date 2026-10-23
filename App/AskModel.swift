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
        model = try? database.state(.chatgptModel, as: String.self)
        Task {
            await refreshAccount()
            if account?.canUsePlan == true { await loadModels() }
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

    func stop() {
        answering?.cancel()
    }

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
