import Foundation
import Testing
@testable import UniversityKit

@Suite struct AcademicTermTests {
    @Test(arguments: [
        ("Deskriptive&WR SoSe26", AcademicTerm(.summer, 2026)),
        ("Statistik SoSe 2025", AcademicTerm(.summer, 2025)),
        ("Mathe SS 26", AcademicTerm(.summer, 2026)),
        ("Sommersemester 2026 Analysis", AcademicTerm(.summer, 2026)),
        ("SchlStat WiSe26/27", AcademicTerm(.winter, 2026)),
        ("Sustainable Finance WiSe 26/27", AcademicTerm(.winter, 2026)),
        ("Winfo I WS 26/27", AcademicTerm(.winter, 2026)),
        ("PM WS26", AcademicTerm(.winter, 2026)),
        ("Wintersemester 2025/2026", AcademicTerm(.winter, 2025)),
        ("Repeat course SoSe25 / WiSe 25/26", AcademicTerm(.winter, 2025)),  // the latest wins
    ])
    func parsesTermNames(name: String, expected: AcademicTerm) {
        #expect(AcademicTerm.parse(name) == expected)
    }

    @Test(arguments: ["Inv+Fin", "Process Mining", "News WS", "CS2026 Lab", "Klasse 2026"])
    func ignoresNamesWithoutATerm(name: String) {
        #expect(AcademicTerm.parse(name) == nil)
    }

    @Test func currentTermFollowsTheGermanCalendar() {
        func on(_ day: String) -> AcademicTerm {
            AcademicTerm.current(at: ISO8601DateFormatter().date(from: "\(day)T12:00:00+02:00")!)
        }
        #expect(on("2026-10-23") == AcademicTerm(.winter, 2026))
        #expect(on("2027-02-15") == AcademicTerm(.winter, 2026))
        #expect(on("2026-04-01") == AcademicTerm(.summer, 2026))
        #expect(on("2026-09-30") == AcademicTerm(.summer, 2026))
        #expect(AcademicTerm(.winter, 2026).label == "WiSe 26/27")
        #expect(AcademicTerm(.summer, 2026).label == "SoSe 26")
    }

    @Test func termInNameBeatsEndDate() {
        let farFuture = Int(fixtureNow.timeIntervalSince1970) + 300 * 86_400
        let past = Int(fixtureNow.timeIntervalSince1970) - 86_400
        // Moodle's default end date (a year after start) would keep SoSe26 active.
        #expect(!MoodleSync.isActive(name: "Deskriptive&WR SoSe26", enddate: farFuture, now: fixtureNow))
        #expect(MoodleSync.isActive(name: "DeMIS WiSe 26/27", enddate: past, now: fixtureNow))
        // No term: the end date decides, 0 means open-ended.
        #expect(MoodleSync.isActive(name: "Inv+Fin", enddate: 0, now: fixtureNow))
        #expect(!MoodleSync.isActive(name: "Inv+Fin", enddate: past, now: fixtureNow))
    }

    @Test func overrideWinsAndCanBeReset() async throws {
        let harness = try MoodleHarness()
        // SoSe26 with a far-future end date, as on the real site.
        let courses = String(decoding: fixture("core_enrol_get_users_courses"), as: UTF8.self)
            .replacingOccurrences(of: "\"enddate\":1790726400", with: "\"enddate\":1822262400")
        harness.moodle.override("core_enrol_get_users_courses", json: courses)
        _ = try await harness.sync().runFast()
        let past = try #require(try await harness.database.writer.read { db in
            try UniCourse.filter(sql: "external_id = '102'").fetchOne(db)
        })
        #expect(!past.active)

        try harness.database.setCourseActive(id: past.id!, override: true)
        _ = try await harness.sync().runFast()
        #expect(try await harness.database.writer.read { db in try UniCourse.fetchOne(db, key: past.id) }?.active == true)

        try harness.database.setCourseActive(id: past.id!, override: nil)
        let reset = try await harness.database.writer.read { db in try UniCourse.fetchOne(db, key: past.id) }
        #expect(reset?.active == false)
        #expect(reset?.activeOverride == nil)
    }
}
