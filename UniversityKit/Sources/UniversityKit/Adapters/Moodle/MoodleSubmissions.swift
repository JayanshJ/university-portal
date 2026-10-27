import Foundation

/// What an assignment accepts, from `mod_assign_get_assignments`.
public struct AssignmentRules: Sendable, Equatable {
    public var assignId: Int
    public var cmid: Int
    public var name: String
    /// The task description, as plain text.
    public var intro: String
    public var dueDate: Date?
    /// After this, Moodle refuses submissions.
    public var cutoffDate: Date?
    public var acceptsFiles: Bool
    public var maxFiles: Int
    /// 0 = the course or site limit.
    public var maxBytes: Int64
    /// Extensions or groups like ".pdf", "document"; empty = any.
    public var fileTypes: [String]
    public var acceptsText: Bool
    public var wordLimit: Int?
    /// "Require students to click the submit button": saving makes a draft, submitting is separate.
    public var usesDrafts: Bool
    public var requiresStatement: Bool
    public var statement: String?
    public var attachments: [SubmittedFile]
}

public struct SubmittedFile: Sendable, Equatable, Hashable {
    public var filename: String
    public var fileURL: String
    public var size: Int64
}

/// The student's current submission, from `mod_assign_get_submission_status`.
public struct SubmissionState: Sendable, Equatable {
    public enum Status: String, Sendable { case new, draft, submitted, reopened }

    public var status: Status
    public var files: [SubmittedFile]
    public var text: String?
    public var modified: Date?
    public var canEdit: Bool
    public var canSubmit: Bool
    public var locked: Bool
    public var graded: Bool
    public var grade: String?
    public var extensionDue: Date?
}

/// A file to hand in: its name and contents.
public struct SubmissionFile: Sendable, Equatable {
    public var filename: String
    public var data: Data

    public init(filename: String, data: Data) {
        self.filename = filename
        self.data = data
    }
}

public enum SubmissionError: Error, Equatable, Sendable {
    case notAnAssignment
    /// Moodle saved nothing; its warning text.
    case refused(String)
    case upload(String)
}

/// Submits Moodle assignments the way the Moodle app does: upload the files to a draft area
/// (`webservice/upload.php`), save the submission with that draft, then submit it for grading.
public struct MoodleSubmissions: Sendable {
    public static let requiredFunctions: Set<String> = [
        "core_course_get_course_module", "mod_assign_get_assignments", "mod_assign_get_submission_status",
        "mod_assign_save_submission", "mod_assign_submit_for_grading",
    ]

    let client: MoodleClient
    private static let log = Log(category: "submit")

    public init(client: MoodleClient) {
        self.client = client
    }

    /// The assignment's module ID from its view URL (`mod/assign/view.php?id=…`).
    public static func cmid(fromURL url: String?) -> Int? {
        guard let url, url.contains("/mod/assign/view.php"),
              let id = URLComponents(string: url)?.queryItems?.first(where: { $0.name == "id" })?.value else { return nil }
        return Int(id)
    }

    // MARK: - Reading

    public func rules(cmid: Int) async throws -> AssignmentRules {
        let module: CourseModuleResponse = try await client.call("core_course_get_course_module", [.int("cmid", cmid)])
        guard module.cm.modname == "assign" else { throw SubmissionError.notAnAssignment }
        let response: AssignmentsResponse = try await client.call(
            "mod_assign_get_assignments", [.ints("courseids", [module.cm.course])])
        guard let assignment = response.courses.flatMap(\.assignments).first(where: { $0.cmid == cmid }) else {
            throw SubmissionError.notAnAssignment
        }
        return assignment.rules
    }

    public func state(assignId: Int) async throws -> SubmissionState {
        let response: StatusResponse = try await client.call(
            "mod_assign_get_submission_status", [.int("assignid", assignId)])
        return response.state
    }

    /// Downloads a file already in the submission, to keep it when the files are replaced.
    public func download(_ file: SubmittedFile) async throws -> SubmissionFile {
        SubmissionFile(filename: file.filename, data: try await client.download(file.fileURL).data)
    }

    // MARK: - Writing

    /// Saves `files` (the submission's complete file list) and `text`. With drafts enabled this
    /// leaves a draft; otherwise it is the submission.
    public func save(assignId: Int, files: [SubmissionFile]?, text: String?) async throws {
        var parameters: [MoodleParameter] = [.int("assignmentid", assignId)]
        let draft = try await upload(files ?? [])
        if files != nil {
            parameters.append(.int("plugindata[files_filemanager]", draft))
        }
        if let text {
            parameters += [
                .value("plugindata[onlinetext_editor][text]", Self.html(text)),
                .int("plugindata[onlinetext_editor][format]", 1),
                .int("plugindata[onlinetext_editor][itemid]", draft),
            ]
        }
        let warnings: [Warning] = try await client.call("mod_assign_save_submission", parameters)
        if let warning = warnings.first { throw SubmissionError.refused(warning.message) }
        Self.log.info("Saved submission for assignment \(assignId): \(files?.count ?? 0) files")
    }

    /// Turns the draft into a submission for grading. Afterwards it can't be changed.
    public func submitForGrading(assignId: Int, acceptStatement: Bool) async throws {
        let warnings: [Warning] = try await client.call("mod_assign_submit_for_grading", [
            .int("assignmentid", assignId), .int("acceptsubmissionstatement", acceptStatement ? 1 : 0),
        ])
        if let warning = warnings.first { throw SubmissionError.refused(warning.message) }
        Self.log.info("Submitted assignment \(assignId) for grading")
    }

    /// Uploads files into a new draft area and returns its item ID. No files: 0, which Moodle
    /// treats as an empty draft area.
    func upload(_ files: [SubmissionFile]) async throws -> Int {
        guard !files.isEmpty else { return 0 }
        let boundary = "UniversityPortal-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("token", client.token)
        field("filearea", "draft")
        field("itemid", "0")
        field("filepath", "/")
        for (index, file) in files.enumerated() {
            let name = file.filename.replacingOccurrences(of: "\"", with: "'")
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file_\(index + 1)\"; filename=\"\(name)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
            body.append(file.data)
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: client.siteURL.appending(path: "webservice/upload.php"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await client.transport.send(request)
        guard (200..<300).contains(response.statusCode) else { throw MoodleError.http(status: response.statusCode) }
        if let failure = try? JSONDecoder().decode(UploadFailure.self, from: data) {
            throw failure.errorcode == "invalidtoken" ? MoodleError.invalidToken : SubmissionError.upload(failure.error)
        }
        if let failure = try? JSONDecoder().decode(MoodleException.self, from: data) { throw failure.error }
        guard let uploaded = try? JSONDecoder().decode([Uploaded].self, from: data), let first = uploaded.first,
              uploaded.allSatisfy({ $0.itemid == first.itemid }), uploaded.count == files.count else {
            throw SubmissionError.upload("Moodle didn't confirm the upload.")
        }
        return first.itemid
    }

    /// Plain text as the HTML Moodle's editor stores: escaped, one paragraph per blank-line block.
    static func html(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        return escaped.components(separatedBy: "\n\n")
            .map { "<p>" + $0.replacingOccurrences(of: "\n", with: "<br>") + "</p>" }
            .joined()
    }
}

// MARK: - Responses

private struct CourseModuleResponse: Decodable {
    struct Module: Decodable {
        var course: Int
        var instance: Int
        var modname: String
    }
    var cm: Module
}

private struct Warning: Decodable {
    var message: String
}

private struct UploadFailure: Decodable {
    var error: String
    var errorcode: String?
}

private struct Uploaded: Decodable {
    var itemid: Int
    var filename: String
}

private struct File: Decodable {
    var filename: String
    var fileurl: String
    var filesize: Int64?

    var submitted: SubmittedFile { SubmittedFile(filename: filename, fileURL: fileurl, size: filesize ?? 0) }
}

private struct AssignmentsResponse: Decodable {
    struct Course: Decodable {
        var assignments: [Assignment]
    }

    struct Config: Decodable {
        var plugin: String
        var subtype: String
        var name: String
        var value: String
    }

    struct Assignment: Decodable {
        var id: Int
        var cmid: Int
        var name: String
        var duedate: Int?
        var cutoffdate: Int?
        var submissiondrafts: Int?
        var requiresubmissionstatement: Int?
        var submissionstatement: String?
        var intro: String?
        var introattachments: [File]?
        var configs: [Config]

        func config(_ plugin: String, _ name: String) -> String? {
            configs.first { $0.subtype == "assignsubmission" && $0.plugin == plugin && $0.name == name }?.value
        }

        var rules: AssignmentRules {
            let date = { (seconds: Int?) in seconds.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil } }
            let wordLimitOn = config("onlinetext", "wordlimitenabled") == "1"
            return AssignmentRules(
                assignId: id, cmid: cmid, name: HTMLText.decodeEntities(name),
                intro: HTMLText.plainText(intro ?? ""),
                dueDate: date(duedate), cutoffDate: date(cutoffdate),
                acceptsFiles: config("file", "enabled") == "1",
                maxFiles: Int(config("file", "maxfilesubmissions") ?? "") ?? 1,
                maxBytes: Int64(config("file", "maxsubmissionsizebytes") ?? "") ?? 0,
                fileTypes: (config("file", "filetypeslist") ?? "")
                    .split(whereSeparator: { ", ;".contains($0) }).map(String.init),
                acceptsText: config("onlinetext", "enabled") == "1",
                wordLimit: wordLimitOn ? Int(config("onlinetext", "wordlimit") ?? "") : nil,
                usesDrafts: submissiondrafts == 1,
                requiresStatement: requiresubmissionstatement == 1,
                statement: submissionstatement.map(HTMLText.plainText).flatMap { $0.isEmpty ? nil : $0 },
                attachments: (introattachments ?? []).map(\.submitted))
        }
    }

    var courses: [Course]
}

private struct StatusResponse: Decodable {
    struct Plugin: Decodable {
        struct Area: Decodable { var files: [File]? }
        struct Editor: Decodable { var name: String; var text: String }
        var type: String
        var fileareas: [Area]?
        var editorfields: [Editor]?
    }

    struct Submission: Decodable {
        var status: String
        var timemodified: Int?
        var plugins: [Plugin]?
    }

    struct Attempt: Decodable {
        var submission: Submission?
        var teamsubmission: Submission?
        var canedit: Bool?
        var cansubmit: Bool?
        var locked: Bool?
        var graded: Bool?
        var extensionduedate: Int?
    }

    struct Feedback: Decodable {
        var gradefordisplay: String?
    }

    var lastattempt: Attempt?
    var feedback: Feedback?

    var state: SubmissionState {
        let submission = lastattempt?.submission ?? lastattempt?.teamsubmission
        let plugins = submission?.plugins ?? []
        let files = plugins.filter { $0.type == "file" }.flatMap { $0.fileareas ?? [] }.flatMap { $0.files ?? [] }
        let text = plugins.first { $0.type == "onlinetext" }?.editorfields?.first?.text
        return SubmissionState(
            status: SubmissionState.Status(rawValue: submission?.status ?? "new") ?? .new,
            files: files.map(\.submitted),
            text: text.map(HTMLText.plainText).flatMap { $0.isEmpty ? nil : $0 },
            modified: submission?.timemodified.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil },
            canEdit: lastattempt?.canedit ?? false,
            canSubmit: lastattempt?.cansubmit ?? false,
            locked: lastattempt?.locked ?? false,
            graded: lastattempt?.graded ?? false,
            grade: feedback?.gradefordisplay.map(HTMLText.plainText),
            extensionDue: lastattempt?.extensionduedate.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil })
    }
}
