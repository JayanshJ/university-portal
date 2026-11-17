import Foundation
import Testing

@testable import UniversityKit

@Suite struct SubmissionRulesTests {
    let ada = StudentDetails(name: "Ada Lovelace", matrikelnr: "2571234", email: "ada@uni.de")

    @Test func parsesJSONInsideProseAndFences() {
        let reply = """
            Here you go:
            ```json
            {"header": ["name", "matrikelnr", "bogus", "partner_names"], "filename": "Blatt{sheet}.pdf", "other": ["stapled"], "quote": "Bitte Name und Matrikelnummer angeben"}
            ```
            """
        let rules = SubmissionRules.parse(reply)
        #expect(rules.header == [.name, .matrikelnr, .partnerNames])
        #expect(rules.filename == "Blatt{sheet}.pdf")
        #expect(rules.other == ["stapled"])
    }

    @Test func garbageGivesNoRules() {
        #expect(SubmissionRules.parse("Sorry") == .none)
        #expect(SubmissionRules.parse("{not json}") == .none)
    }

    @Test func noRulesGivesPlainHeaderAndFilename() {
        let rules = SubmissionRules.none
        #expect(
            rules.filename(student: ada, course: CourseDetails(), assignment: "Übungsblatt 3", sheet: 3, courseShort: "AD")
                == "Übungsblatt 3 - Ada Lovelace.pdf")
        let header = rules.header(student: ada, course: CourseDetails(), courseName: "Analysis", sheetTitle: "Blatt 3")
        #expect(header.map(\.label) == ["Name", "Course", "Sheet"])
        #expect(header.map(\.value) == ["Ada Lovelace", "Analysis", "Blatt 3"])
    }

    @Test func filenamePatternIsFilledAndCleaned() {
        let rules = SubmissionRules(header: [.name], filename: "Blatt{sheet}_{lastname}_{matrikelnr}.pdf")
        #expect(
            rules.filename(student: ada, course: CourseDetails(), assignment: "x", sheet: 3, courseShort: "AD")
                == "Blatt3_Lovelace_2571234.pdf")
        let grouped = SubmissionRules(header: [.name], filename: "{group}_{firstname}")
        #expect(
            grouped.filename(student: ada, course: CourseDetails(group: "A/B"), assignment: "x", sheet: nil, courseShort: "AD")
                == "A-B_Ada.pdf")
    }

    @Test func emptyPlaceholderIsMissing() {
        let rules = SubmissionRules(header: [], filename: "{group}.pdf")
        #expect(rules.missing(student: ada, course: CourseDetails()) == [.group])
        #expect(rules.missing(student: ada, course: CourseDetails(group: "3")) == [])
    }

    @Test func partnerMatrikelnrIsMissingWhenAPartnerLacksIt() {
        let rules = SubmissionRules(header: [.partnerNames, .partnerMatrikelnr])
        #expect(rules.missing(student: ada, course: CourseDetails()) == [.partnerNames, .partnerMatrikelnr])
        let partial = CourseDetails(partners: [Partner(name: "Bob", matrikelnr: "1"), Partner(name: "Cy")])
        #expect(rules.missing(student: ada, course: partial) == [.partnerMatrikelnr])
        let full = CourseDetails(partners: [Partner(name: "Bob", matrikelnr: "1"), Partner(name: "Cy", matrikelnr: "2")])
        #expect(rules.missing(student: ada, course: full) == [])
        let header = rules.header(student: ada, course: full, courseName: "C", sheetTitle: "S")
        #expect(header[0].value == "Bob, Cy")
        #expect(header[1].value == "1, 2")
    }

    @Test func germanLabelsForGermanSheets() {
        let rules = SubmissionRules(
            header: [.name, .matrikelnr, .group, .tutorial, .partnerNames],
            quote: "Bitte geben Sie Ihren Namen und die Matrikelnummer an.")
        let labels = rules.header(student: ada, course: CourseDetails(), courseName: "C", sheetTitle: "S").map(\.label)
        #expect(labels == ["Name", "Matrikelnummer", "Gruppe", "Übungsgruppe", "Partner", "Kurs", "Blatt"])
        let english = SubmissionRules(header: [.matrikelnr], quote: "Put your student ID on top.")
        #expect(english.header(student: ada, course: CourseDetails(), courseName: "C", sheetTitle: "S")[0].label != "Matrikelnummer")
    }

    @Test func siteInfoDecodesFullname() throws {
        var json = try #require(
            try JSONSerialization.jsonObject(with: fixture("core_webservice_get_site_info")) as? [String: Any])
        json["fullname"] = "Ada Lovelace"
        let info = try JSONDecoder().decode(MoodleSiteInfo.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(info.fullname == "Ada Lovelace")
    }

    @Test func courseDetailsRoundTripPerCourse() throws {
        let database = try UniDatabase.inMemory()
        try CourseDetails(group: "4", tutorial: "Mo", partners: [Partner(name: "Bob")]).save(database, courseId: 1)
        try CourseDetails(group: "7").save(database, courseId: 2)
        #expect(CourseDetails.load(database, courseId: 1).partners.first?.name == "Bob")
        #expect(CourseDetails.load(database, courseId: 2).group == "7")
        #expect(CourseDetails.load(database, courseId: 3) == CourseDetails())
        #expect(StudentDetails.load(database).name == "")
        try database.setState(.moodleFullName, to: "Ada Lovelace")
        #expect(StudentDetails.load(database).name == "Ada Lovelace")
        try StudentDetails(name: "Grace").save(database)
        #expect(StudentDetails.load(database).name == "Grace")
    }
}
