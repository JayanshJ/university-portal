import Foundation
import GRDB
import Testing
@testable import UniversityKit

@Suite struct MoodleClientTests {
    @Test func arraysAreFlattenedAndEscaped() {
        let fields = MoodleParameter.ints("courseids", [101, 103]).fields + MoodleParameter.value("q", "a&b c").fields
        #expect(FormEncoding.encode(fields) == "courseids%5B0%5D=101&courseids%5B1%5D=103&q=a%26b%20c")
    }

    @Test func invalidTokenIsRecognized() async {
        let client = MoodleClient(token: "garbage", transport: FakeMoodle())
        await #expect(throws: MoodleError.invalidToken) {
            let _: MoodleSiteInfo = try await client.call("core_webservice_get_site_info")
        }
    }

    @Test func otherExceptionsKeepTheirCode() async {
        let moodle = FakeMoodle()
        moodle.override("core_webservice_get_site_info", fixture: "error_servicenotavailable")
        let client = MoodleClient(token: FakeMoodle.validToken, transport: moodle)
        await #expect(throws: MoodleError.moodle(errorcode: "servicenotavailable",
                                                 message: "Web service is not available (it doesn't exist or might be disabled)")) {
            let _: MoodleSiteInfo = try await client.call("core_webservice_get_site_info")
        }
    }

    @Test func entitiesAreDecoded() {
        #expect(HTMLText.decodeEntities("Deskriptive&amp;WR SoSe26") == "Deskriptive&WR SoSe26")
        #expect(HTMLText.decodeEntities("&#252;ber &#x00FC; &lt;b&gt; & more") == "über ü <b> & more")
    }

    @Test func deadlineSuffixIsStripped() {
        #expect(MoodleSync.deadlineTitle("Blatt 2 ist fällig.") == "Blatt 2")
        #expect(MoodleSync.deadlineTitle("Quiz 1 is due") == "Quiz 1")
        #expect(MoodleSync.deadlineTitle("Is due date known") == "Is due date known")
    }
}

@Suite struct LaunchTokenTests {
    static func encoded(_ raw: String) -> String { Data(raw.utf8).base64EncodedString() }

    @Test func parsesCallbackHeaderAndBareValue() throws {
        let value = Self.encoded("abc123:::tok456:::priv789")
        let expected = MoodleLaunchToken(siteHash: "abc123", token: "tok456", privateToken: "priv789")
        #expect(try MoodleLaunchToken.parse("moodlemobile://token=\(value)") == expected)
        #expect(try MoodleLaunchToken.parse("location: moodlemobile://token=\(value)\n") == expected)
        #expect(try MoodleLaunchToken.parse(value) == expected)
    }

    @Test func toleratesMissingPaddingAndNoPrivateToken() throws {
        let value = Self.encoded("h:::t").replacingOccurrences(of: "=", with: "")
        #expect(try MoodleLaunchToken.parse("moodlemobile://token=\(value)")
                == MoodleLaunchToken(siteHash: "h", token: "t", privateToken: nil))
    }

    @Test func rejectsGarbage() {
        #expect(throws: MoodleLaunchToken.ParseError.noToken) { try MoodleLaunchToken.parse("moodlemobile://token=") }
        #expect(throws: MoodleLaunchToken.ParseError.wrongShape) { try MoodleLaunchToken.parse(Self.encoded("no separators")) }
    }

    @Test func siteHashIsMd5OfWwwrootAndPassport() {
        // md5("https://moodle.uni-saarland.de" + "passport123")
        #expect(MoodleLaunchToken.expectedSiteHash(passport: "passport123") == "4f6be6fa5c6bc7041d9bbe70342ef64e")
    }
}

@Suite struct MoodleConnectorTests {
    func launchValue(hash: String, token: String) -> String {
        "moodlemobile://token=" + Data("\(hash):::\(token):::private".utf8).base64EncodedString()
    }

    @Test func reconnectStoresTokenAndRecordsHashMatch() async throws {
        let harness = try MoodleHarness()
        let secrets = InMemorySecrets()
        let connector = MoodleConnector(database: harness.database, secrets: secrets, transport: harness.moodle)

        let url = try connector.beginReconnect(now: fixtureNow)
        let passport = try #require(try harness.database.state(.moodlePassport, as: MoodlePassport.self))
        #expect(url.absoluteString.contains("passport=\(passport.value)"))
        #expect(url.absoluteString.hasPrefix("https://moodle.uni-saarland.de/admin/tool/mobile/launch.php?service=moodle_mobile_app"))

        let hash = MoodleLaunchToken.expectedSiteHash(passport: passport.value)
        let info = try await connector.complete(with: launchValue(hash: hash, token: FakeMoodle.validToken), via: .sheet, now: fixtureNow)

        #expect(info.userid == 1234)
        #expect(try secrets.readString(.moodleToken) == FakeMoodle.validToken)
        #expect(try secrets.readString(.moodlePrivateToken) == "private")
        #expect(try harness.database.source(.moodle).status == .ok)
        #expect(try harness.database.state(.moodlePassport, as: MoodlePassport.self) == nil)
        let diagnostics = try harness.database.state(.moodleDiagnostics, as: MoodleDiagnostics.self)
        #expect(diagnostics?.siteHashMatched == true)
        #expect(diagnostics?.connectedVia == .sheet)
        #expect(diagnostics?.release?.hasPrefix("4.5.11") == true)
    }

    @Test func hashMismatchIsRecordedButNotFatal() async throws {
        let harness = try MoodleHarness()
        let connector = MoodleConnector(database: harness.database, secrets: InMemorySecrets(), transport: harness.moodle)
        _ = try connector.beginReconnect(now: fixtureNow)

        try await connector.complete(with: launchValue(hash: "deadbeef", token: FakeMoodle.validToken), via: .paste, now: fixtureNow)

        #expect(try harness.database.state(.moodleDiagnostics, as: MoodleDiagnostics.self)?.siteHashMatched == false)
    }

    @Test func rejectedTokenStoresNothing() async throws {
        let harness = try MoodleHarness()
        let secrets = InMemorySecrets()
        let connector = MoodleConnector(database: harness.database, secrets: secrets, transport: harness.moodle)

        await #expect(throws: MoodleConnector.ConnectError.tokenRejected) {
            try await connector.complete(with: launchValue(hash: "x", token: "garbage"), via: .paste)
        }
        #expect(try secrets.read(.moodleToken) == nil)
    }
}

@Suite struct MoodleSyncTests {
    @Test func fastSyncStoresCoursesDeadlinesAndAnnouncements() async throws {
        let harness = try MoodleHarness()

        let outcome = try await harness.sync().runFast()

        let courses = try await harness.database.writer.read { db in try UniCourse.order(sql: "external_id").fetchAll(db) }
        #expect(courses.map(\.shortName) == ["PM WS26", "Deskriptive&WR SoSe26", "ALGO"])
        #expect(courses.map(\.active) == [true, false, true])  // SoSe26 ended

        let deadlines = try harness.items(.deadline)
        #expect(deadlines.map(\.title) == ["Blatt 2", "Quiz 1", "Blatt 1"])  // personal event skipped
        #expect(deadlines.first?.dueAt == Date(timeIntervalSince1970: 1_793_404_740))
        #expect(deadlines.map(\.category) == ["assign", "quiz", "assign"])

        let announcements = try harness.items(.announcement)
        #expect(Set(announcements.map(\.title)) == ["Lecture mode", "Welcome & organisation", "Sheet 1 is out"])
        // Only the two news forums are read; the general Q&A forum is skipped.
        #expect(harness.moodle.calls.filter { $0 == "mod_forum_get_forum_discussions" }.count == 2)

        #expect(outcome.counts.new == 6)
        #expect(outcome.events.count == 6)
        #expect(try harness.database.state(.moodleDiagnostics, as: MoodleDiagnostics.self)?.deadlinesMode == .actionEvents)
    }

    @Test func secondRunReportsNothingNew() async throws {
        let harness = try MoodleHarness()
        _ = try await harness.sync().runFast()

        let second = try await harness.sync().runFast()

        #expect(second.counts.new == 0)
        #expect(second.counts.updated == 0)
        #expect(second.counts.unchanged == 6)
        #expect(second.events.isEmpty)
    }

    @Test func movedDeadlineIsAnUpdateWithDueDateChange() async throws {
        let harness = try MoodleHarness()
        _ = try await harness.sync().runFast()
        let moved = String(decoding: fixture("core_calendar_get_action_events_by_timesort"), as: UTF8.self)
            .replacingOccurrences(of: "1793404740", with: "1793491140")
        harness.moodle.override("core_calendar_get_action_events_by_timesort", json: moved)

        let outcome = try await harness.sync().runFast()

        #expect(outcome.counts.updated == 1)
        #expect(outcome.events.contains { if case .itemUpdated(_, true) = $0 { true } else { false } })
    }

    @Test func submittedDeadlineIsMarkedDoneAfterTwoMisses() async throws {
        let harness = try MoodleHarness()
        _ = try await harness.sync().runFast()
        // Blatt 2 (5001) submitted: gone from the open list. Blatt 1 (5003) was already overdue.
        harness.moodle.override("core_calendar_get_action_events_by_timesort", json: """
            {"events":[{"id":5002,"name":"Quiz 1 is due","modulename":"quiz","course":{"id":103},"timesort":1794009540,"url":"u"}]}
            """)

        let first = try await harness.sync().runFast()
        #expect(first.counts.missing == 2)
        #expect(try harness.items(.deadline).allSatisfy { $0.doneAt == nil && $0.deletedAt == nil })

        harness.clock.advance(hours: 0.5)
        let second = try await harness.sync().runFast()

        let byTitle = Dictionary(uniqueKeysWithValues: try harness.items(.deadline).map { ($0.title, $0) })
        #expect(byTitle["Blatt 2"]?.doneSource == .moodle)
        #expect(byTitle["Blatt 2"]?.deletedAt == nil)
        #expect(byTitle["Blatt 1"]?.deletedAt != nil)  // past due: soft-deleted, not "done"
        #expect(byTitle["Quiz 1"]?.doneAt == nil)
        #expect(second.counts.doneByMoodle == 1)
        #expect(second.counts.deleted == 1)
    }

    @Test func refusedActionEventsFallBackToAssignments() async throws {
        let harness = try MoodleHarness()
        harness.moodle.override("core_calendar_get_action_events_by_timesort", fixture: "error_servicenotavailable")

        _ = try await harness.sync().runFast()

        let deadlines = try harness.items(.deadline)
        #expect(deadlines.map(\.title) == ["Blatt 2"])  // Blatt 0 out of range, Bonus has no due date
        #expect(deadlines.first?.externalId == "assign:901")
        let diagnostics = try harness.database.state(.moodleDiagnostics, as: MoodleDiagnostics.self)
        #expect(diagnostics?.deadlinesMode == .assignFallback)
        #expect(diagnostics?.deadlinesFallbackReason?.hasPrefix("servicenotavailable") == true)
    }

    @Test func materialsCoverActiveCoursesOnly() async throws {
        let harness = try MoodleHarness()
        _ = try await harness.sync().runFast()

        let outcome = try await harness.sync().runMaterials()

        let materials = try harness.items(.material)
        #expect(Set(materials.map(\.title)) == ["01-intro.pdf", "sheet1.pdf", "data.zip", "ProM download", "script.pdf"])
        // 101 and 103 only: SoSe26 (102) is inactive.
        #expect(harness.moodle.calls.filter { $0 == "core_course_get_contents" }.count == 2)
        #expect(materials.first { $0.title == "sheet1.pdf" }?.category == "Week 1 & 2")
        #expect(materials.first { $0.title == "ProM download" }?.url == "https://promtools.org/")
        #expect(outcome.counts.new == 5)

        let files = try await harness.database.writer.read { db in try UniFile.fetchAll(db) }
        #expect(files.count == 4)  // the URL module has no file
        #expect(files.allSatisfy { $0.localPath == nil })
    }

    @Test func activatingAPastCourseAddsItsMaterials() async throws {
        let harness = try MoodleHarness()
        _ = try await harness.sync().runFast()
        let past = try await harness.database.writer.read { db in
            try UniCourse.filter(sql: "external_id = '102'").fetchOne(db)
        }
        try harness.database.setCourseActive(id: past!.id!, override: true)

        _ = try await harness.sync().runFast()  // the override survives a sync
        _ = try await harness.sync().runMaterials()

        #expect(try harness.items(.material).contains { $0.title == "old.pdf" })
    }

    @Test func emptyResultForACourseWithItemsKeepsThemAndFlagsIt() async throws {
        let harness = try MoodleHarness()
        _ = try await harness.sync().runFast()
        _ = try await harness.sync().runMaterials()
        harness.moodle.override("core_course_get_contents.101", json: "[]")

        let outcome = try await harness.sync().runMaterials()
        _ = try await harness.sync().runMaterials()

        #expect(outcome.suspectCourseIds.count == 1)
        #expect(try harness.items(.material).allSatisfy { $0.deletedAt == nil })
    }

    @Test func removedMaterialIsDeletedOnlyOnSecondMiss() async throws {
        let harness = try MoodleHarness()
        _ = try await harness.sync().runFast()
        _ = try await harness.sync().runMaterials()
        // Course 101 now has only its slides.
        harness.moodle.override("core_course_get_contents.101", json: """
            [{"id":1,"name":"General","modules":[{"id":402,"name":"Slides 01","modname":"resource","contents":[
             {"type":"file","filename":"01-intro.pdf","filepath":"/","filesize":1048576,"fileurl":"https://moodle.uni-saarland.de/webservice/pluginfile.php/55/mod_resource/content/1/01-intro.pdf?forcedownload=1","timemodified":1790841600,"mimetype":"application/pdf"}]}]}]
            """)

        _ = try await harness.sync().runMaterials()
        #expect(try harness.items(.material).filter { $0.deletedAt != nil }.isEmpty)

        _ = try await harness.sync().runMaterials()
        let deleted = try harness.items(.material).filter { $0.deletedAt != nil }.map(\.title)
        #expect(Set(deleted) == ["sheet1.pdf", "data.zip", "ProM download"])
    }
}

@Suite struct SchedulerAndFilesTests {
    @Test func garbageTokenSetsNeedsReconnect() async throws {
        let harness = try MoodleHarness()
        try harness.secrets.writeString("garbage", for: .moodleToken)
        let scheduler = SyncScheduler(database: harness.database, secrets: harness.secrets, transport: harness.moodle)

        await scheduler.run(.moodleFast)

        #expect(try harness.database.source(.moodle).status == .needsReconnect)
        let run = try await harness.database.writer.read { db in try UniSyncRun.fetchOne(db) }
        #expect(run?.ok == false)
        #expect(run?.error == "invalidtoken")

        // No retries until the user reconnects.
        await scheduler.run(.moodleMaterials)
        #expect(try await harness.database.writer.read { db in try UniSyncRun.fetchCount(db) } == 1)
    }

    @Test func goodRunIsRecordedWithCounts() async throws {
        let harness = try MoodleHarness()
        let scheduler = SyncScheduler(database: harness.database, secrets: harness.secrets, transport: harness.moodle)

        await scheduler.runNow(.moodle)

        let runs = try await harness.database.writer.read { db in try UniSyncRun.order(sql: "id").fetchAll(db) }
        #expect(runs.map(\.job) == ["moodle.fast", "moodle.materials"])
        #expect(runs.allSatisfy { $0.ok == true })
        #expect(runs.first?.counts?["new"] == 6)
        #expect(try harness.database.source(.moodle).status == .ok)
    }

    @Test func openingAFileDownloadsOnceAndMarksRead() async throws {
        let harness = try MoodleHarness()
        _ = try await harness.sync().runFast()
        _ = try await harness.sync().runMaterials()
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = MaterialFiles(database: harness.database, cache: FileCache(directory: directory),
                                  secrets: harness.secrets, transport: harness.moodle)
        let slides = try #require(try harness.items(.material).first { $0.title == "01-intro.pdf" })

        let url = try await files.open(itemId: slides.id!)
        let again = try await files.open(itemId: slides.id!)

        #expect(url == again)
        #expect(url.pathExtension == "pdf")
        #expect(try Data(contentsOf: url) == FakeMoodle.pdfBytes)
        #expect(harness.moodle.downloads == 1)
        let stored = try await harness.database.writer.read { db in try UniFile.fetchOne(db, key: slides.id!) }
        #expect(stored?.localPath == url.path)
        #expect(try harness.items(.material).first { $0.id == slides.id }?.readAt != nil)

        // A later sync with the same remote file keeps the cached copy.
        _ = try await harness.sync().runMaterials()
        #expect(try await harness.database.writer.read { db in try UniFile.fetchOne(db, key: slides.id!) }?.localPath == url.path)
    }
}
