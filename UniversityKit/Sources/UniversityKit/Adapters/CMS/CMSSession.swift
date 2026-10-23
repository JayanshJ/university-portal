import Foundation
import SwiftSoup

public enum CMSAuthError: Error, Equatable {
    /// No username or password saved yet.
    case noCredentials
    /// The page had no login form to fill in.
    case loginFormMissing
    /// The CMS showed the login form again: wrong username or password.
    case loginRejected
    /// Logged in again, but the page still says "login required".
    case stillLoggedOut
    /// The last login failed less than 15 minutes ago.
    case waitBeforeRetry(until: Date)
}

/// Login bookkeeping in `uni_state`, so a wrong password cannot turn into repeated attempts.
public struct CMSLoginState: Codable, Sendable, Equatable {
    public var lastAttemptAt: Date?
    public var lastFailureAt: Date?
    public var lastSuccessAt: Date?
    public var logins = 0

    public init() {}
}

/// A logged-in view of the CMS: restores the saved cookie jar, logs in when the session has
/// lapsed (once per request), and saves the new jar.
public struct CMSSession: Sendable {
    public static let retryDelay: TimeInterval = 15 * 60

    let database: UniDatabase
    let secrets: any SecretStore
    let client: CMSClient
    let now: @Sendable () -> Date

    private static let log = Log(category: "cms.session")

    /// `client` should be fresh; its cookie jar is replaced with the saved one.
    public init(database: UniDatabase, secrets: any SecretStore, client: CMSClient,
                now: @escaping @Sendable () -> Date = { .now }) async {
        self.database = database
        self.secrets = secrets
        self.client = client
        self.now = now
        if let data = try? secrets.read(.cmsCookieJar), let jar = try? JSONDecoder().decode(CookieJar.self, from: data) {
            await client.setCookieJar(jar)
        }
    }

    public var hasCredentials: Bool {
        (try? secrets.readString(.cmsUsername)).flatMap { $0 } != nil
            && (try? secrets.readString(.cmsPassword)).flatMap { $0 } != nil
    }

    /// A page that needs login. Logs in first if there is no session, and once more if the session lapsed.
    public func page(_ path: String, entryPath: String) async throws -> CMSClient.Page {
        if await client.cookieJar.isEmpty {
            try await login(entryPath: entryPath)
        }
        let page = try await client.fetch(path)
        guard Self.isLoggedOut(page) else { return page }

        Self.log.info("CMS session lapsed at \(path); logging in again")
        try await login(entryPath: entryPath)
        let retry = try await client.fetch(path)
        guard !Self.isLoggedOut(retry) else { throw CMSAuthError.stillLoggedOut }
        return retry
    }

    /// Saves the jar, whose session cookie the CMS refreshes on use.
    public func saveCookies() async throws {
        let jar = await client.cookieJar
        guard !jar.isEmpty else { return }
        try secrets.write(try JSONEncoder().encode(jar), for: .cmsCookieJar)
    }

    /// Fills in the login form found on `entryPath` exactly as rendered and submits it.
    public func login(entryPath: String) async throws {
        guard let username = try secrets.readString(.cmsUsername),
              let password = try secrets.readString(.cmsPassword) else { throw CMSAuthError.noCredentials }

        let state = try database.state(.cmsLogin, as: CMSLoginState.self) ?? CMSLoginState()
        if let failure = state.lastFailureAt, now().timeIntervalSince(failure) < Self.retryDelay {
            throw CMSAuthError.waitBeforeRetry(until: failure.addingTimeInterval(Self.retryDelay))
        }
        try database.updateState(.cmsLogin, default: CMSLoginState()) { $0.lastAttemptAt = now() }

        let entry = try await client.fetch(entryPath)
        guard let form = try Self.loginForm(in: entry.body, username: username, password: password) else {
            throw CMSAuthError.loginFormMissing
        }
        let result = try await client.post(form.action, fields: form.fields)

        if Self.isLoggedOut(result) {
            try database.updateState(.cmsLogin, default: CMSLoginState()) { $0.lastFailureAt = now() }
            Self.log.warning("CMS login rejected (HTTP \(result.status) at \(result.url.path))")
            throw CMSAuthError.loginRejected
        }
        try secrets.write(try JSONEncoder().encode(await client.cookieJar), for: .cmsCookieJar)
        try database.updateState(.cmsLogin, default: CMSLoginState()) {
            $0.lastFailureAt = nil
            $0.lastSuccessAt = now()
            $0.logins += 1
        }
        Self.log.info("CMS login succeeded")
    }

    // MARK: - Pages

    /// The form with a password input, with every field the browser would send, in document order.
    /// SecurityComponent rejects any request whose fields differ from the rendered form.
    static func loginForm(in html: String, username: String, password: String) throws -> (action: String, fields: [(String, String)])? {
        let document = try SwiftSoup.parse(html)
        guard let form = try document.select("form").first(where: { try !$0.select("input[type=password]").isEmpty() }) else {
            return nil
        }
        var fields: [(String, String)] = []
        for input in try form.select("input[name]") {
            let name = try input.attr("name")
            switch try input.attr("type").lowercased() {
            case "password":
                fields.append((name, password))
            case "text", "email", "":
                fields.append((name, username))
            case "checkbox":
                // Only "remember me" is on this form; tick it so the session lasts.
                fields.append((name, try input.attr("value").isEmpty ? "on" : input.attr("value")))
            case "hidden":
                fields.append((name, try input.attr("value")))
            default:
                continue
            }
        }
        for button in try form.select("button[name], input[type=submit][name]") {
            fields.append((try button.attr("name"), try button.attr("value")))
        }
        return (try form.attr("action"), fields)
    }

    /// Logged out: sent to the login page, or (with no logout link) a password field or the
    /// "You need to login" notice on the page. Files (non-HTML) are never a login page.
    static func isLoggedOut(_ page: CMSClient.Page) -> Bool {
        if page.url.path.hasSuffix("/users/login") { return true }
        guard page.mimeType == nil || page.mimeType == "text/html" else { return false }
        let body = page.body
        if body.contains("/users/logout") { return false }
        return body.contains("type=\"password\"") || body.contains("You need to login")
    }
}
