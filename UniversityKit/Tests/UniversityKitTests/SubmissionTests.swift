import Foundation
import Testing
@testable import UniversityKit

@Suite struct SubmissionTests {
    let moodle = FakeMoodle()
    var submissions: MoodleSubmissions { MoodleSubmissions(client: MoodleClient(token: FakeMoodle.validToken, transport: moodle)) }

    init() {
        moodle.override("core_course_get_course_module", json: #"{"cm":{"id":484160,"course":101,"instance":55,"modname":"assign","name":"Exercise Sheet 1"},"warnings":[]}"#)
        moodle.override("mod_assign_get_assignments", json: """
            {"courses":[{"id":101,"assignments":[
              {"id":54,"cmid":1,"name":"Other","duedate":0,"configs":[]},
              {"id":55,"cmid":484160,"name":"Exercise Sheet 1","duedate":1792886340,"cutoffdate":1792972740,
               "submissiondrafts":1,"requiresubmissionstatement":1,
               "submissionstatement":"<p>This is my own work.</p>",
               "intro":"<p>Solve tasks 1&ndash;3 &amp; upload a PDF.</p>",
               "introattachments":[{"filename":"sheet1.pdf","fileurl":"https://moodle.uni-saarland.de/webservice/pluginfile.php/1/mod_assign/introattachment/0/sheet1.pdf","filesize":1234}],
               "configs":[
                 {"plugin":"file","subtype":"assignsubmission","name":"enabled","value":"1"},
                 {"plugin":"file","subtype":"assignsubmission","name":"maxfilesubmissions","value":"2"},
                 {"plugin":"file","subtype":"assignsubmission","name":"maxsubmissionsizebytes","value":"10485760"},
                 {"plugin":"file","subtype":"assignsubmission","name":"filetypeslist","value":".pdf,.zip"},
                 {"plugin":"onlinetext","subtype":"assignsubmission","name":"enabled","value":"0"},
                 {"plugin":"comments","subtype":"assignsubmission","name":"enabled","value":"1"}]}]}],"warnings":[]}
            """)
    }

    @Test func moduleIdComesFromTheViewURL() {
        #expect(MoodleSubmissions.cmid(fromURL: "https://moodle.uni-saarland.de/mod/assign/view.php?id=484160") == 484160)
        #expect(MoodleSubmissions.cmid(fromURL: "https://moodle.uni-saarland.de/mod/quiz/view.php?id=5") == nil)
        #expect(MoodleSubmissions.cmid(fromURL: nil) == nil)
    }

    @Test func rulesComeFromTheAssignmentSettings() async throws {
        let rules = try await submissions.rules(cmid: 484160)
        #expect(rules.assignId == 55)
        #expect(rules.acceptsFiles && !rules.acceptsText)
        #expect(rules.maxFiles == 2)
        #expect(rules.maxBytes == 10_485_760)
        #expect(rules.fileTypes == [".pdf", ".zip"])
        #expect(rules.usesDrafts && rules.requiresStatement)
        #expect(rules.statement == "This is my own work.")
        #expect(rules.intro == "Solve tasks 1–3 & upload a PDF.")
        #expect(rules.attachments.map(\.filename) == ["sheet1.pdf"])
        #expect(moodle.fields(of: "mod_assign_get_assignments")?["courseids[0]"] == "101")
    }

    @Test func aQuizIsNotAnAssignment() async throws {
        moodle.override("core_course_get_course_module", json: #"{"cm":{"id":9,"course":101,"instance":3,"modname":"quiz","name":"Quiz"}}"#)
        await #expect(throws: SubmissionError.notAnAssignment) { try await submissions.rules(cmid: 9) }
    }

    @Test func stateReadsTheSubmissionAndGrade() async throws {
        moodle.override("mod_assign_get_submission_status", json: """
            {"lastattempt":{"submission":{"status":"submitted","timemodified":1792800000,"plugins":[
               {"type":"file","fileareas":[{"area":"submission_files","files":[{"filename":"answers.pdf","fileurl":"https://moodle.uni-saarland.de/webservice/pluginfile.php/2/assignsubmission_file/submission_files/9/answers.pdf","filesize":2048}]}]},
               {"type":"onlinetext","editorfields":[{"name":"onlinetext","text":"","format":1}]}]},
             "canedit":false,"cansubmit":false,"locked":false,"graded":true},
             "feedback":{"gradefordisplay":"8.00&nbsp;/&nbsp;10.00"},"warnings":[]}
            """)
        let state = try await submissions.state(assignId: 55)
        #expect(state.status == .submitted)
        #expect(state.files.map(\.filename) == ["answers.pdf"])
        #expect(state.files.first?.size == 2048)
        #expect(state.text == nil)
        #expect(state.graded && !state.canEdit)
        #expect(state.grade?.replacingOccurrences(of: "\u{00A0}", with: " ") == "8.00 / 10.00")
    }

    @Test func noAttemptYetIsNew() async throws {
        moodle.override("mod_assign_get_submission_status", json: #"{"lastattempt":{"cansubmit":false,"canedit":true},"warnings":[]}"#)
        let state = try await submissions.state(assignId: 55)
        #expect(state.status == .new && state.canEdit && state.files.isEmpty)
    }

    @Test func saveUploadsTheFilesIntoOneDraftAndSavesIt() async throws {
        moodle.override("mod_assign_save_submission", json: "[]")
        let files = [SubmissionFile(filename: "answers.pdf", data: Data("%PDF answers".utf8)),
                     SubmissionFile(filename: "code \"v2\".zip", data: Data([0, 1, 2, 13, 10, 255]))]
        try await submissions.save(assignId: 55, files: files, text: nil)

        #expect(moodle.uploads.map(\.name) == ["answers.pdf", "code 'v2'.zip"])
        #expect(moodle.uploads.map(\.data) == files.map(\.data))
        let saved = try #require(moodle.fields(of: "mod_assign_save_submission"))
        #expect(saved["assignmentid"] == "55")
        #expect(saved["plugindata[files_filemanager]"] == String(FakeMoodle.draftItemId))
        #expect(saved["plugindata[onlinetext_editor][text]"] == nil)
    }

    @Test func onlineTextIsSavedAsEscapedParagraphs() async throws {
        moodle.override("mod_assign_save_submission", json: "[]")
        try await submissions.save(assignId: 55, files: nil, text: "a < b & c\nnext\n\nsecond")
        let saved = try #require(moodle.fields(of: "mod_assign_save_submission"))
        #expect(saved["plugindata[onlinetext_editor][text]"] == "<p>a &lt; b &amp; c<br>next</p><p>second</p>")
        #expect(saved["plugindata[files_filemanager]"] == nil)
        #expect(moodle.uploads.isEmpty)
    }

    @Test func aWarningMeansNothingWasSaved() async throws {
        moodle.override("mod_assign_save_submission", json: #"[{"item":"Exercise Sheet 1","itemid":55,"warningcode":"couldnotsavesubmission","message":"This assignment is not accepting submissions"}]"#)
        await #expect(throws: SubmissionError.refused("This assignment is not accepting submissions")) {
            try await submissions.save(assignId: 55, files: [SubmissionFile(filename: "a.pdf", data: Data("x".utf8))], text: nil)
        }
    }

    @Test func submitForGradingSendsTheStatementAcceptance() async throws {
        moodle.override("mod_assign_submit_for_grading", json: "[]")
        try await submissions.submitForGrading(assignId: 55, acceptStatement: true)
        let fields = try #require(moodle.fields(of: "mod_assign_submit_for_grading"))
        #expect(fields["assignmentid"] == "55" && fields["acceptsubmissionstatement"] == "1")
    }

    @Test func uploadWithADeadTokenNeedsReconnecting() async throws {
        let dead = MoodleSubmissions(client: MoodleClient(token: "dead", transport: moodle))
        await #expect(throws: MoodleError.invalidToken) {
            try await dead.save(assignId: 55, files: [SubmissionFile(filename: "a.pdf", data: Data("x".utf8))], text: nil)
        }
    }

    @Test func siteInfoSaysWhetherSubmittingIsAllowed() throws {
        let names = MoodleSubmissions.requiredFunctions.map { #"{"name":"\#($0)"}"# }.joined(separator: ",")
        let allowed = try JSONDecoder().decode(MoodleSiteInfo.self, from: Data(#"{"userid":1,"uploadfiles":1,"functions":[\#(names)]}"#.utf8))
        #expect(allowed.canSubmitAssignments)
        let noUpload = try JSONDecoder().decode(MoodleSiteInfo.self, from: Data(#"{"userid":1,"uploadfiles":0,"functions":[\#(names)]}"#.utf8))
        #expect(!noUpload.canSubmitAssignments)
        let fixtureInfo = try JSONDecoder().decode(MoodleSiteInfo.self, from: fixture("core_webservice_get_site_info"))
        #expect(!fixtureInfo.canSubmitAssignments)
    }
}
