import Foundation
import Testing
@testable import UniversityKit

@Suite struct SecretsTests {
    /// A separate service per run, so tests never touch the app's real items.
    let store = KeychainStore(service: "app.jayansh.UniversityPortal.tests.\(UUID().uuidString)")

    @Test func secretRoundTripsThroughKeychain() throws {
        defer { try? store.delete(.moodleToken) }

        try store.writeString("first-token", for: .moodleToken)
        #expect(try store.readString(.moodleToken) == "first-token")

        try store.writeString("second-token", for: .moodleToken)
        #expect(try store.readString(.moodleToken) == "second-token")

        try store.delete(.moodleToken)
        #expect(try store.read(.moodleToken) == nil)
    }

    @Test func deletingAMissingSecretSucceeds() throws {
        try store.delete(.cmsPassword)
    }
}

@Suite struct RedactionTests {
    @Test func moodleTokenInRestCallIsRedacted() {
        let line = Log.render("POST server.php wstoken=abc&wsfunction=core_webservice_get_site_info")
        #expect(line == "POST server.php wstoken=[REDACTED]&wsfunction=core_webservice_get_site_info")
        #expect(!line.contains("abc"))
    }

    @Test func fileUrlTokenIsRedacted() {
        let line = Log.render("GET https://moodle.uni-saarland.de/webservice/pluginfile.php/1/a.pdf?forcedownload=1&token=s3cret")
        #expect(line.hasSuffix("&token=[REDACTED]"))
    }

    @Test func launchRedirectIsRedacted() {
        #expect(Log.render("Location: moodlemobile://token=YWJjOjo6ZGVm") == "Location: moodlemobile://token=[REDACTED]")
    }

    @Test func cmsPasswordIsRedacted() {
        let plain = Log.render("data[User][username]=jayansh&data[User][password]=hunter2&data[Auth][remember_me]=1")
        #expect(plain == "data[User][username]=jayansh&data[User][password]=[REDACTED]&data[Auth][remember_me]=1")

        let encoded = Log.render("data%5BUser%5D%5Bpassword%5D=hunter2")
        #expect(encoded == "data%5BUser%5D%5Bpassword%5D=[REDACTED]")

        #expect(Log.render(#"{"password": "hunter2"}"#) == #"{"password": "[REDACTED]"}"#)
    }

    @Test func ordinaryTextIsUnchanged() {
        let line = "Synced 7 courses, 3 new deadlines"
        #expect(Log.render(line) == line)
    }
}

@Suite struct FileCacheTests {
    @Test func storedBytesAreFoundByHash() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let cache = FileCache(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let (sha256, url) = try await cache.store(Data("%PDF-1.7".utf8), filename: "Slides.PDF")

        #expect(url.lastPathComponent == "\(sha256).pdf")
        #expect(await cache.cachedURL(sha256: sha256, filename: "Slides.PDF") == url)
        #expect(try await cache.sizeInBytes() == 8)

        try await cache.clear()
        #expect(await cache.cachedURL(sha256: sha256, filename: "Slides.PDF") == nil)
    }
}
