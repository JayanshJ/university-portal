import AppKit
import AuthenticationServices
import SwiftUI
import UniversityKit

@main
struct UniversityPortalApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("University Portal", id: "main") {
            ContentView()
                .environment(model)
                .preferredColorScheme(.dark)
                // The browser hands moodlemobile://token=… to this window instead of opening a new one.
                .handlesExternalEvents(preferring: ["moodlemobile"], allowing: ["*"])
                .onOpenURL { url in
                    Task { await model.handleOpenURL(url) }
                }
        }
        .defaultSize(width: 1000, height: 680)
        .handlesExternalEvents(matching: ["moodlemobile"])

        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(.dark)
        }

        MenuBarExtra("University Portal", systemImage: "graduationcap") {
            MenuBarView()
                .environment(model)
        }
    }
}

/// App-wide state: owns the database, the sync scheduler and the Moodle connection.
@MainActor @Observable
final class AppModel {
    let database: UniDatabase?
    let startupError: String?
    private(set) var overview = PortalOverview()
    private(set) var isConnecting = false
    private(set) var isSyncing = false
    private(set) var isMoodleConnected = false
    var message: String?

    @ObservationIgnored private let secrets = KeychainStore()
    @ObservationIgnored private let transport = URLSessionTransport(session: URLSession(configuration: .ephemeral))
    @ObservationIgnored private let signIn = MoodleSignIn()
    @ObservationIgnored private var scheduler: SyncScheduler?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    private static let log = Log(category: "app")

    init() {
        do {
            let database = try UniDatabase.onDisk()
            self.database = database
            startupError = nil
            Self.log.info("Opened database at \(AppPaths.databaseURL.path)")
        } catch {
            database = nil
            startupError = "Could not open the database: \(error)"
            Self.log.error(startupError!)
        }
        guard let database else { return }
        isMoodleConnected = (try? secrets.read(.moodleToken)) != nil

        let scheduler = SyncScheduler(database: database, secrets: secrets, transport: transport)
        self.scheduler = scheduler
        Task { await scheduler.start() }

        Task { [weak self] in
            do {
                for try await overview in database.overviewUpdates() { self?.overview = overview }
            } catch {
                Self.log.error("Overview observation stopped: \(error)")
            }
        }

        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { await scheduler.catchUp() }
        })
    }

    private var connector: MoodleConnector? {
        database.map { MoodleConnector(database: $0, secrets: secrets, transport: transport) }
    }

    // MARK: - Moodle

    /// Primary reconnect: open the launch link in the default browser, where you are usually already
    /// logged in. Moodle redirects to `moodlemobile://token=…`, which macOS hands to this app.
    func connectMoodleInBrowser() {
        guard let connector else { return }
        do {
            NSWorkspace.shared.open(try connector.beginReconnect())
            message = "Finish in your browser. When it asks to open University Portal, allow it."
        } catch {
            message = Self.describe(error)
        }
    }

    func handleOpenURL(_ url: URL) async {
        guard url.scheme == "moodlemobile", let connector, !isConnecting else { return }
        Self.log.info("Received moodlemobile callback: \(url.absoluteString)")  // token is redacted
        isConnecting = true
        defer { isConnecting = false }
        do {
            try await connector.complete(with: url.absoluteString, via: .browser)
            isMoodleConnected = true
            message = "Moodle connected."
            NSApp.activate()
            await syncNow()
        } catch {
            message = Self.describe(error)
        }
    }

    /// Secondary: the system sign-in sheet catches the redirect without leaving the app.
    func connectMoodleWithSheet() async {
        guard let connector, let database, !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }
        message = nil
        do {
            let launchURL = try connector.beginReconnect()
            let callback = try await signIn.callbackURL(for: launchURL)
            try await connector.complete(with: callback.absoluteString, via: .sheet)
            isMoodleConnected = true
            message = "Moodle connected."
            await syncNow()
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            try? database.updateState(.moodleDiagnostics, default: MoodleDiagnostics()) {
                $0.sheetFailure = "Sheet closed before Moodle returned a token"
            }
            message = "Sign-in cancelled. If the sheet never finished, use the paste box instead."
        } catch {
            try? database.updateState(.moodleDiagnostics, default: MoodleDiagnostics()) {
                $0.sheetFailure = Redactor.redact(String(describing: error))
            }
            message = Self.describe(error)
        }
    }

    /// Fallback: the launch link to open in a browser where you are logged in.
    func makeLaunchLink() -> URL? {
        try? connector?.beginReconnect()
    }

    func connectMoodle(pasted text: String) async {
        guard let connector, !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }
        message = nil
        do {
            try await connector.complete(with: text, via: .paste)
            isMoodleConnected = true
            message = "Moodle connected."
            await syncNow()
        } catch {
            message = Self.describe(error)
        }
    }

    func disconnectMoodle() {
        try? connector?.disconnect()
        isMoodleConnected = false
        message = "Moodle disconnected. Your data stays until you reconnect."
    }

    func syncNow() async {
        guard let scheduler, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        await scheduler.runNow()
        // Loops sleeping on a delay computed before this run would otherwise sync again too soon.
        await scheduler.catchUp()
    }

    func setCourse(_ id: Int64, active: Bool) {
        try? database?.setCourseActive(id: id, override: active)
    }

    func resetCourse(_ id: Int64) {
        try? database?.setCourseActive(id: id, override: nil)
    }

    // MARK: - Files

    func open(_ item: PortalOverview.ItemRow) async {
        guard let database else { return }
        if !item.hasFile {
            if let link = item.url.flatMap(URL.init(string:)) { NSWorkspace.shared.open(link) }
            return
        }
        do {
            let files = MaterialFiles(database: database, cache: FileCache(), secrets: secrets, transport: transport)
            NSWorkspace.shared.open(try await files.open(itemId: item.id))
        } catch {
            message = Self.describe(error)
        }
    }

    func openLink(_ item: PortalOverview.ItemRow) {
        if let link = item.url.flatMap(URL.init(string:)) { NSWorkspace.shared.open(link) }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case MoodleConnector.ConnectError.unreadable:
            "That doesn't contain a Moodle token. Paste the whole location value starting with moodlemobile://token="
        case MoodleConnector.ConnectError.tokenRejected:
            "Moodle rejected that token. Start again with a fresh launch link."
        case MoodleError.invalidToken:
            "Moodle no longer accepts the token. Reconnect in Settings."
        case let error as LocalizedError where error.errorDescription != nil:
            error.errorDescription!
        default:
            Redactor.redact(String(describing: error))
        }
    }
}
