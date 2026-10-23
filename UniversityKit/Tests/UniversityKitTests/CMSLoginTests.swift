import Foundation
import GRDB
import Testing
@testable import UniversityKit

/// A CMS with a login: checks the posted form field by field like SecurityComponent, sets a session
/// cookie on success, and serves materials and files only to that session.
final class FakeCMSWithLogin: HTTPTransport, @unchecked Sendable {
    static let password = "right-password"
    static let pdf = Data("%PDF-1.7 cms".utf8)

    private let lock = NSLock()
    private var validSessions: Set<String> = []
    private var loginPosts = 0
    private var lastFields: [(String, String)] = []

    var logins: Int { lock.withLock { loginPosts } }
    var postedFields: [(String, String)] { lock.withLock { lastFields } }

    /// Ends every session, as when the CMS session cookie expires.
    func expireSessions() { lock.withLock { validSessions = [] } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let path = url.path(percentEncoded: true)
        let session = (request.value(forHTTPHeaderField: "Cookie") ?? "")
            .split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("CakeCMS=") }.map { String($0.dropFirst("CakeCMS=".count)) }
        let loggedIn = session.map { s in lock.withLock { validSessions.contains(s) } } ?? false

        if request.httpMethod == "POST", path == "/prog1_26/users/login" {
            let fields = String(decoding: request.httpBody ?? Data(), as: UTF8.self).split(separator: "&").map { pair in
                let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
                return (parts[0], parts.count > 1 ? parts[1] : "")
            }
            lock.withLock { loginPosts += 1; lastFields = fields }
            let expected = ["_method", "data[_Token][key]", "data[User][username]", "data[User][password]",
                            "data[Auth][remember_me]", "data[Auth][remember_me]", "data[User][redirect]",
                            "data[_Token][fields]", "data[_Token][unlocked]"]
            guard fields.map(\.0) == expected else {
                return response(url, 400, body: "The request has been black-holed")
            }
            guard fields.first(where: { $0.0 == "data[User][password]" })?.1 == Self.password else {
                return response(url, 200, body: cmsFixture("prog1_26.main.html"))  // the login form again
            }
            let token = UUID().uuidString
            lock.withLock { validSessions.insert(token) }
            return response(url, 302, headers: [
                "Location": "https://cms.sic.saarland/prog1_26/landing",
                "Set-Cookie": "CakeCMS=\(token); path=/; secure; HttpOnly",
            ])
        }

        switch path {
        case "/prog1_26/":
            return response(url, 200, body: cmsFixture("prog1_26.main.html"),
                            headers: session == nil ? ["Set-Cookie": "CakeCMS=anonymous; path=/; secure; HttpOnly"] : [:])
        case "/prog1_26/landing":
            return response(url, 200, body: "<html><a href=\"/prog1_26/users/logout\">Logout</a> Your status</html>")
        case "/prog1_26/materials/":
            return response(url, 200, body: cmsFixture(loggedIn ? "prog1_26.materials.synthetic.html"
                                                               : "prog1_26.materials.loggedout.html"))
        default:
            if path.hasPrefix("/prog1_26/dl/") {
                return loggedIn
                    ? response(url, 200, data: Self.pdf, headers: ["Content-Type": "application/pdf"])
                    : response(url, 200, body: cmsFixture("prog1_26.materials.loggedout.html"))
            }
            // Public pages (calendar, course list) come from the recorded fixtures.
            if let name = FakeCMS.fixtureName(for: path) {
                return response(url, 200, body: cmsFixture(name))
            }
            return response(url, 404, body: "Not Found")
        }
    }

    private func response(_ url: URL, _ status: Int, body: String = "", data: Data? = nil,
                          headers: [String: String] = [:]) -> (Data, HTTPURLResponse) {
        var headers = headers
        if headers["Content-Type"] == nil { headers["Content-Type"] = "text/html; charset=UTF-8" }
        return (data ?? Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
}

@Suite struct CMSLoginTests {
    struct Harness {
        let database: UniDatabase
        let cms = FakeCMSWithLogin()
        let secrets = InMemorySecrets()
        let clock = TestClock()

        init(password: String = FakeCMSWithLogin.password) async throws {
            database = try UniDatabase.inMemory()
            try secrets.writeString("student", for: .cmsUsername)
            try secrets.writeString(password, for: .cmsPassword)
            let listing = CMSCourseListing(slug: "prog1_26", name: "Programming 1", lecturer: nil,
                                           term: AcademicTerm(.winter, 2026), termHeading: "Winter term 2026/2027")
            try database.setCMSCourse(listing, selected: true)
        }

        func client() -> CMSClient { CMSClient(transport: cms, minimumInterval: .zero) }

        func session() async -> CMSSession {
            let clock = clock
            return await CMSSession(database: database, secrets: secrets, client: client(), now: { clock.now })
        }

        func runMaterials() async throws -> SyncOutcome {
            let client = client()
            let clock = clock
            let session = await CMSSession(database: database, secrets: secrets, client: client, now: { clock.now })
            return try await CMSSync(database: database, client: client, now: { clock.now }).runMaterials(session: session)
        }
    }

    @Test func loginFormIsCopiedExactly() throws {
        let form = try #require(try CMSSession.loginForm(in: cmsFixture("prog1_26.main.html"), username: "student", password: "pw"))
        #expect(form.action == "/prog1_26/users/login")
        #expect(form.fields.map(\.0) == ["_method", "data[_Token][key]", "data[User][username]", "data[User][password]",
                                         "data[Auth][remember_me]", "data[Auth][remember_me]", "data[User][redirect]",
                                         "data[_Token][fields]", "data[_Token][unlocked]"])
        #expect(form.fields.map(\.1) == ["POST", "FIXTURE", "student", "pw", "0", "1",
                                         "https://cms.sic.saarland/prog1_26/landing", "FIXTURE", ""])
    }

    @Test func loggedOutPagesAreRecognized() {
        func page(_ name: String, path: String = "/prog1_26/materials/") -> CMSClient.Page {
            CMSClient.Page(data: Data(cmsFixture(name).utf8), url: URL(string: "https://cms.sic.saarland\(path)")!,
                           status: 200, mimeType: "text/html")
        }
        #expect(CMSSession.isLoggedOut(page("prog1_26.materials.loggedout.html")))
        #expect(!CMSSession.isLoggedOut(page("prog1_26.materials.synthetic.html")))
        #expect(CMSSession.isLoggedOut(page("prog1_26.materials.synthetic.html", path: "/prog1_26/users/login")))
        let pdf = CMSClient.Page(data: Data("%PDF".utf8), url: URL(string: "https://cms.sic.saarland/prog1_26/dl/1/a.pdf")!,
                                 status: 200, mimeType: "application/pdf")
        #expect(!CMSSession.isLoggedOut(pdf))
    }

    @Test func materialsAreParsedWithSections() throws {
        let materials = try CMSPages.materials(cmsFixture("prog1_26.materials.synthetic.html"), slug: "prog1_26")
        #expect(materials.map(\.id) == [10, 21, 22, 31, 32])  // "Download all" and the duplicate link are skipped
        #expect(materials.map(\.section) == ["Organisation", "Lecture Slides", "Lecture Slides", "Exercise Sheets", "Exercise Sheets"])
        #expect(materials.first { $0.id == 22 }?.filename == "02_Recursion and Types.pdf")
        #expect(materials.first { $0.id == 22 }?.title == "02 Recursion and Types")
        #expect(materials.first { $0.id == 31 }?.title == "sheet01.pdf")  // empty link text: the file name
        #expect(materials.first { $0.id == 32 }?.path == "/prog1_26/dl/32/sheet01_code.zip")  // absolute link
        #expect(try CMSPages.materials(cmsFixture("prog1_26.materials.loggedout.html"), slug: "prog1_26").isEmpty)

        // Links to other sites are materials too; same-site non-file links are not.
        let links = try CMSPages.materialsPage(cmsFixture("prog1_26.materials.synthetic.html"), slug: "prog1_26").links
        #expect(links == [CMSMaterialLink(url: "https://ghpages.neuralcoder.de/interactive_sheets/", title: "Sheet A",
                                          section: "Exercise Sheets")])
    }

    @Test func firstRunLogsInOnceAndStoresMaterials() async throws {
        let harness = try await Harness()

        let outcome = try await harness.runMaterials()

        #expect(harness.cms.logins == 1)
        #expect(outcome.counts.new == 6)  // 5 files and 1 link
        let jar = try #require(try harness.secrets.read(.cmsCookieJar))
        #expect(String(decoding: jar, as: UTF8.self).contains("CakeCMS"))
        let files = try await harness.database.writer.read { db in try UniFile.fetchAll(db) }
        #expect(files.count == 5)
        #expect(files.contains { $0.remoteUrl == "https://cms.sic.saarland/prog1_26/dl/22/02_Recursion%20and%20Types.pdf" })
        #expect(files.first { $0.filename == "sheet01.pdf" }?.mimetype == "application/pdf")
    }

    @Test func savedSessionIsReusedWithoutLoggingIn() async throws {
        let harness = try await Harness()
        _ = try await harness.runMaterials()

        let second = try await harness.runMaterials()

        #expect(harness.cms.logins == 1)
        #expect(second.counts.unchanged == 6)
    }

    @Test func expiredSessionTriggersExactlyOneRelogin() async throws {
        let harness = try await Harness()
        _ = try await harness.runMaterials()
        harness.cms.expireSessions()

        let outcome = try await harness.runMaterials()

        #expect(harness.cms.logins == 2)
        #expect(outcome.counts.unchanged == 6)
    }

    @Test func deletedCookieJarTriggersExactlyOneLogin() async throws {
        let harness = try await Harness()
        _ = try await harness.runMaterials()
        try harness.secrets.delete(.cmsCookieJar)

        _ = try await harness.runMaterials()

        #expect(harness.cms.logins == 2)
    }

    @Test func wrongPasswordFailsOnceThenWaits() async throws {
        let harness = try await Harness(password: "wrong")

        await #expect(throws: CMSAuthError.loginRejected) { _ = try await harness.runMaterials() }
        #expect(harness.cms.logins == 1)

        // A retry within 15 minutes does not reach the server.
        harness.clock.advance(hours: 0.2)
        await #expect(throws: CMSAuthError.self) { _ = try await harness.runMaterials() }
        #expect(harness.cms.logins == 1)
    }

    @Test func schedulerStopsAfterAWrongPassword() async throws {
        let harness = try await Harness(password: "wrong")
        let scheduler = SyncScheduler(database: harness.database, secrets: harness.secrets, transport: harness.cms)

        await scheduler.run(.cmsMaterials)
        #expect(try harness.database.source(.cms).status == .needsReconnect)

        // The hourly public job still runs (and succeeds) but does not hide the failed login.
        await scheduler.run(.cmsPublic)
        await scheduler.run(.cmsMaterials)
        #expect(harness.cms.logins == 1)
        #expect(try harness.database.source(.cms).status == .needsReconnect)
        let jobs = try await harness.database.writer.read { db in try UniSyncRun.order(sql: "id").fetchAll(db) }
        #expect(jobs.map(\.job) == ["cms.materials", "cms.public"])  // the second materials run was skipped
        #expect(jobs.last?.ok == true)
    }

    @Test func cmsFileDownloadUsesTheSession() async throws {
        let harness = try await Harness()
        _ = try await harness.runMaterials()
        let item = try #require(try await harness.database.writer.read { db in
            try UniItem.filter(sql: "external_id = '22'").fetchOne(db)
        })
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = MaterialFiles(database: harness.database, cache: FileCache(directory: directory),
                                  secrets: harness.secrets, transport: harness.cms)
        harness.cms.expireSessions()

        let url = try await files.open(itemId: item.id!)

        #expect(try Data(contentsOf: url) == FakeCMSWithLogin.pdf)
        #expect(url.pathExtension == "pdf")
        #expect(harness.cms.logins == 2)  // the lapsed session was renewed once
    }
}

@Suite struct CookieJarTests {
    @Test func storesSendsAndDeletesCookies() {
        var jar = CookieJar()
        let url = URL(string: "https://cms.sic.saarland/prog1_26/")!
        jar.store(from: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                        headerFields: ["Set-Cookie": "CakeCMS=abc; path=/; secure; HttpOnly"])!, for: url)
        #expect(jar.header(for: URL(string: "https://cms.sic.saarland/system/courses")!) == "CakeCMS=abc")
        #expect(jar.header(for: URL(string: "http://cms.sic.saarland/")!) == nil)  // secure only
        #expect(jar.header(for: URL(string: "https://example.com/")!) == nil)

        jar.store(from: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                        headerFields: ["Set-Cookie": "CakeCMS=deleted; expires=Thu, 01 Jan 1970 00:00:01 GMT; path=/"])!, for: url)
        #expect(jar.isEmpty)
    }
}
