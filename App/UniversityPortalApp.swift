import AppKit
import AuthenticationServices
import ServiceManagement
import SwiftUI
import UniversityKit

@main
struct UniversityPortalApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("University Portal", id: "main") {
            ContentView()
                .environment(model)
                // The browser hands moodlemobile://token=… to this window instead of opening a new one.
                .handlesExternalEvents(preferring: ["moodlemobile"], allowing: ["*"])
                .onOpenURL { url in
                    Task { await model.handleOpenURL(url) }
                }
        }
        .defaultSize(width: 1280, height: 800)
        .handlesExternalEvents(matching: ["moodlemobile"])
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { model.updater.checkForUpdates() }
                    .disabled(!model.updater.canCheck)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }

        WindowGroup("Material", id: "viewer", for: ViewerTarget.self) { $target in
            ViewerWindow(target: target)
                .environment(model)
        }
        .defaultSize(width: 900, height: 1000)

        MenuBarExtra {
            MenuBarView()
                .environment(model)
        } label: {
            // A warning sign replaces the cap when a source needs reconnecting.
            Image(systemName: model.overview.needsReconnect ? "exclamationmark.triangle.fill" : "graduationcap")
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
    /// Where the main window is.
    var selection: Route = .today
    /// The course shown in Materials (nil = the first one).
    var materialsCourse: Int64?
    /// The assignment whose hand-in sheet is open.
    var submitting: SubmitTarget?

    /// "Ask your materials" (nil only when the database could not be opened).
    private(set) var ask: AskModel?
    /// Updates from GitHub Releases (not started in screenshot runs).
    let updater = Updater(start: !CommandLine.arguments.contains("--snapshot"))

    @ObservationIgnored private let secrets = KeychainStore()
    @ObservationIgnored private let transport = URLSessionTransport(session: URLSession(configuration: .ephemeral))
    /// CMS requests keep their own cookies and follow redirects themselves.
    @ObservationIgnored private let cmsTransport = URLSessionTransport.manualRedirectsAndCookies()
    @ObservationIgnored private let signIn = MoodleSignIn()
    @ObservationIgnored private var scheduler: SyncScheduler?
    @ObservationIgnored let events = UniEventHub()
    /// What the most recent syncs brought, from the event stream, for the menu bar.
    private(set) var recentChanges: (new: Int, changed: Int, at: Date)?
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
        // Screenshot runs show stored data only: no Keychain (no password prompts), no syncing.
        // Read-only Moodle audit (see MoodleAudit): report, then quit.
        if CommandLine.arguments.contains("--audit") {
            let secrets = secrets, transport = transport
            Task {
                var iterator = database.overviewUpdates().makeAsyncIterator()
                guard let overview = try? await iterator.next(),
                      let token = (try? secrets.readString(.moodleToken)) ?? nil else { NSApp.terminate(nil); return }
                await MoodleAudit.run(overview: overview, token: token, transport: transport)
            }
            return
        }
        if CommandLine.arguments.contains("--snapshot") {
            isMoodleConnected = true
            Task { [weak self] in
                do {
                    for try await overview in database.overviewUpdates() { self?.overview = overview }
                } catch {}
            }
            let ask = AskModel(database: database, secrets: NoSecrets(), transport: transport, files: files(database))
            self.ask = ask
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                ask.showDemo(courseId: self?.overview.courses.first { $0.shortName.hasPrefix("Programming") }?.id)
            }
            Task { await Snapshotter.run(model: self) }
            return
        }
        isMoodleConnected = (try? secrets.read(.moodleToken)) != nil

        isCMSSignedIn = (try? secrets.readString(.cmsPassword)).flatMap { $0 } != nil
        cmsUsername = (try? secrets.readString(.cmsUsername)).flatMap { $0 }

        let scheduler = SyncScheduler(database: database, secrets: secrets, transport: transport,
                                      cmsTransport: cmsTransport, events: events)
        self.scheduler = scheduler
        Task { await scheduler.start() }
        ask = AskModel(database: database, secrets: secrets, transport: transport, files: files(database))

        Task { [weak self] in
            do {
                for try await overview in database.overviewUpdates() { self?.overview = overview }
            } catch {
                Self.log.error("Overview observation stopped: \(error)")
            }
        }

        Task { [weak self, events] in
            for await event in events.events() { self?.record(event) }
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

    // MARK: - CMS

    private(set) var cmsListing: [CMSCourseListing] = []
    private(set) var cmsListingError: String?
    private(set) var isLoadingCMSListing = false

    /// The public course list for the picker (one request).
    func loadCMSCourses() async {
        guard let database, !isLoadingCMSListing else { return }
        isLoadingCMSListing = true
        defer { isLoadingCMSListing = false }
        do {
            cmsListing = try await CMSSync(database: database, client: CMSClient(transport: cmsTransport)).courseListing()
            cmsListingError = nil
        } catch {
            cmsListingError = "Could not load the CMS course list: \(Self.describe(error))"
        }
    }

    func setCMSCourse(_ listing: CMSCourseListing, selected: Bool) {
        try? database?.setCMSCourse(listing, selected: selected)
    }

    func setCMSCourse(id: Int64, selected: Bool) {
        try? database?.setCourseActive(id: id, override: selected)
    }

    /// After choosing courses: fetch their news, calendars and (when signed in) materials right away.
    func syncCMS() async {
        guard let scheduler else { return }
        isSyncing = true
        defer { isSyncing = false }
        await scheduler.runNow(.cms)
        await scheduler.catchUp()
    }

    private(set) var isCMSSignedIn = false
    private(set) var cmsUsername: String?

    /// Saves the CMS login in the Keychain and tries it once right away.
    func signInCMS(username: String, password: String) async {
        guard let database, !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }
        do {
            try secrets.writeString(username, for: .cmsUsername)
            try secrets.writeString(password, for: .cmsPassword)
            try secrets.delete(.cmsCookieJar)
            try database.removeState(.cmsLogin)  // a new password gets a fresh attempt
            try database.setStatus(.cms, .ok)
            isCMSSignedIn = true
            cmsUsername = username

            let entry = overview.courses.first { $0.source == .cms && $0.active }.map { "/\($0.externalId)/" } ?? "/system/courses"
            let session = await CMSSession(database: database, secrets: secrets, client: CMSClient(transport: cmsTransport))
            try await session.login(entryPath: entry)
            message = "Signed in to CMS."
            await syncCMS()
        } catch CMSAuthError.loginRejected {
            try? database.setStatus(.cms, .needsReconnect, error: "CMS login failed. Check your username and password.")
            message = "CMS didn't accept that username and password. Nothing else will be tried until you change them."
        } catch {
            message = "CMS sign-in failed: \(Self.describe(error))"
        }
    }

    func signOutCMS() {
        for kind in [SecretKind.cmsUsername, .cmsPassword, .cmsCookieJar] { try? secrets.delete(kind) }
        try? database?.removeState(.cmsLogin)
        isCMSSignedIn = false
        cmsUsername = nil
        message = "Signed out of CMS. Its materials stay until you sign in again."
    }

    func eventCategories() -> [Int64: [String]] {
        (try? database?.eventCategories()) ?? [:]
    }

    func hiddenCategories(courseId: Int64) -> Set<String> {
        (try? database?.hiddenCategories(courseId: courseId)) ?? []
    }

    func setCategory(_ category: String, hidden: Bool, courseId: Int64) {
        try? database?.setCategory(category, hidden: hidden, courseId: courseId)
    }

    // MARK: - Items

    func setDone(_ item: PortalOverview.ItemRow, done: Bool) {
        try? database?.setDone(itemId: item.id, done: done)
    }

    func setRead(_ item: PortalOverview.ItemRow, read: Bool) {
        try? database?.setRead(itemId: item.id, read: read)
    }

    func markAllRead(_ kind: ItemKind) {
        try? database?.markAllRead(kind)
    }

    func markTodayVisited() {
        try? database?.markTodayVisited()
    }

    func schedule(from: Date, to: Date) -> [PortalOverview.ItemRow] {
        (try? database?.schedule(from: from, to: to)) ?? []
    }

    /// Groups events that arrive close together (one sync) into one "new / changed" summary.
    private func record(_ event: UniEvent) {
        var summary = recentChanges.flatMap { Date.now.timeIntervalSince($0.at) < 120 ? $0 : nil } ?? (0, 0, .now)
        switch event {
        case .itemCreated: summary.new += 1
        case .itemUpdated: summary.changed += 1
        }
        summary.at = .now
        recentChanges = summary
    }

    // MARK: - Files

    /// The local copy of a material's file, downloaded on first open; opening marks it read.
    func localFile(_ item: PortalOverview.ItemRow) async throws -> URL {
        guard let database else { throw FileCacheError.noFile }
        return try await files(database).open(itemId: item.id)
    }

    private func files(_ database: UniDatabase) -> MaterialFiles {
        MaterialFiles(database: database, cache: FileCache(), secrets: secrets, transport: transport, cmsTransport: cmsTransport)
    }

    func setDarkPages(_ on: Bool) {
        Self.log.info("Dark pages toggled: \(on)")
        do {
            try database?.setState(.pdfDarkPages, to: on)
        } catch {
            Self.log.error("Could not save dark pages: \(error)")
            message = "Could not save the dark pages setting: \(Self.describe(error))"
        }
    }

    func openInDefaultApp(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    // MARK: - Submissions

    /// The hand-in target for a Moodle assignment deadline; nil for quizzes, CMS items and the rest.
    func submitTarget(_ item: PortalOverview.ItemRow) -> SubmitTarget? {
        guard item.kind == .deadline, item.source == .moodle, let cmid = MoodleSubmissions.cmid(fromURL: item.url) else { return nil }
        return SubmitTarget(itemId: item.id, cmid: cmid)
    }

    func submissions() -> MoodleSubmissions? {
        guard let token = (try? secrets.readString(.moodleToken)) ?? nil else { return nil }
        return MoodleSubmissions(client: MoodleClient(token: token, transport: transport))
    }

    func openLink(_ item: PortalOverview.ItemRow) {
        if let link = item.url.flatMap(URL.init(string:)) { NSWorkspace.shared.open(link) }
    }

    // MARK: - Open at login

    var opensAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setOpensAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            message = "Could not change Open at Login: \(error.localizedDescription)"
        }
    }

    func describeError(_ error: Error) -> String { Self.describe(error) }

    private static func describe(_ error: Error) -> String {
        switch error {
        case MoodleConnector.ConnectError.unreadable:
            "That doesn't contain a Moodle token. Paste the whole location value starting with moodlemobile://token="
        case MoodleConnector.ConnectError.tokenRejected:
            "Moodle rejected that token. Start again with a fresh launch link."
        case MoodleError.invalidToken, FileCacheError.notConnected:
            "Moodle no longer accepts the token. Reconnect in Settings."
        case CMSAuthError.noCredentials:
            "Sign in to CMS in Settings to open CMS files."
        case CMSAuthError.loginRejected, CMSAuthError.stillLoggedOut:
            "CMS didn't accept the saved password. Sign in again in Settings."
        case CMSAuthError.waitBeforeRetry(let until):
            "The last CMS login failed; the next attempt is allowed at \(until.formatted(date: .omitted, time: .shortened))."
        case let error as LocalizedError where error.errorDescription != nil:
            error.errorDescription!
        default:
            Redactor.redact(String(describing: error))
        }
    }
}

/// Screenshot runs never touch the Keychain.
private struct NoSecrets: SecretStore {
    func read(_ kind: SecretKind) throws -> Data? { nil }
    func write(_ data: Data, for kind: SecretKind) throws {}
    func delete(_ kind: SecretKind) throws {}
}
