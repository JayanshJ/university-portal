import Foundation
@testable import UniversityKit

/// 2026-10-23 12:00 UTC, the fixtures' "now".
let fixtureNow = Date(timeIntervalSince1970: 1_792_756_800)

func fixture(_ name: String) -> Data {
    let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/moodle")!
    return try! Data(contentsOf: url)
}

/// A movable clock for multi-run tests.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = fixtureNow) { current = start }

    var now: Date { lock.withLock { current } }

    func advance(hours: Double) { lock.withLock { current.addTimeInterval(hours * 3600) } }
}

final class InMemorySecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SecretKind: Data] = [:]

    func read(_ kind: SecretKind) throws -> Data? { lock.withLock { values[kind] } }
    func write(_ data: Data, for kind: SecretKind) throws { lock.withLock { values[kind] = data } }
    func delete(_ kind: SecretKind) throws { _ = lock.withLock { values.removeValue(forKey: kind) } }
}

/// Answers web service calls from the fixtures. A call is looked up as `<wsfunction>.<id>` first
/// (forum id or course id), then `<wsfunction>`. Overrides replace a response with raw JSON.
final class FakeMoodle: HTTPTransport, @unchecked Sendable {
    static let validToken = "good-token"
    static let pdfBytes = Data("%PDF-1.7 fake".utf8)

    private let lock = NSLock()
    private var overrides: [String: Data] = [:]
    private var log: [String] = []
    private var downloadCount = 0
    private var fileBodies: [String: Data] = [:]
    private var lastFields: [String: [String: String]] = [:]
    private var uploadedFiles: [(name: String, data: Data)] = []

    var calls: [String] { lock.withLock { log } }
    /// The form fields of the last call to `function`.
    func fields(of function: String) -> [String: String]? { lock.withLock { lastFields[function] } }
    /// Files received by `webservice/upload.php`.
    var uploads: [(name: String, data: Data)] { lock.withLock { uploadedFiles } }
    static let draftItemId = 777

    /// Serves `data` for files whose URL contains `filename` (default: a tiny fake PDF).
    func serveFile(_ filename: String, data: Data) { lock.withLock { fileBodies[filename] = data } }
    var downloads: Int { lock.withLock { downloadCount } }

    func override(_ key: String, json: String) { lock.withLock { overrides[key] = Data(json.utf8) } }
    func override(_ key: String, fixture name: String) { lock.withLock { overrides[key] = fixture(name) } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        if url.path.contains("pluginfile.php") {
            let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "token" }?.value
            guard token == Self.validToken else { return response(fixture("error_invalidtoken"), url, "application/json") }
            lock.withLock { downloadCount += 1 }
            let body = lock.withLock { fileBodies.first { url.path.contains($0.key) }?.value }
            return response(body ?? Self.pdfBytes, url, "application/pdf")
        }

        if url.path.hasSuffix("webservice/upload.php") {
            return upload(request, url)
        }

        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        let fields = Dictionary(body.split(separator: "&").map { pair -> (String, String) in
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            return (parts[0], parts.count > 1 ? parts[1] : "")
        }, uniquingKeysWith: { first, _ in first })
        let function = fields["wsfunction"] ?? ""
        lock.withLock {
            log.append(function)
            lastFields[function] = fields
        }

        guard fields["wstoken"] == Self.validToken else {
            return response(fixture("error_invalidtoken"), url, "application/json")
        }
        let id = fields["forumid"] ?? fields["courseid"]
        let keys = [id.map { "\(function).\($0)" }, function].compactMap { $0 }
        if let data = lock.withLock({ keys.lazy.compactMap { self.overrides[$0] }.first }) {
            return response(data, url, "application/json")
        }
        for key in keys {
            if Bundle.module.url(forResource: key, withExtension: "json", subdirectory: "Fixtures/moodle") != nil {
                return response(fixture(key), url, "application/json")
            }
        }
        return response(Data("[]".utf8), url, "application/json")
    }

    /// Parses the multipart body like Moodle's upload.php and answers with the draft item.
    private func upload(_ request: URLRequest, _ url: URL) -> (Data, HTTPURLResponse) {
        let type = request.value(forHTTPHeaderField: "Content-Type") ?? ""
        guard let boundary = type.components(separatedBy: "boundary=").last, let body = request.httpBody else {
            return response(Data(#"{"error":"bad request","errorcode":"invalidparameter"}"#.utf8), url, "application/json")
        }
        var token: String?
        var files: [(String, Data)] = []
        let delimiter = Data("--\(boundary)".utf8)
        var parts: [Data] = []
        var rest = body[...]
        while let range = rest.range(of: delimiter) {
            parts.append(Data(rest[..<range.lowerBound]))
            rest = rest[range.upperBound...]
        }
        for part in parts where !part.isEmpty {
            guard let split = part.range(of: Data("\r\n\r\n".utf8)) else { continue }
            let header = String(decoding: part[..<split.lowerBound], as: UTF8.self)
            var content = Data(part[split.upperBound...])
            if content.suffix(2) == Data("\r\n".utf8) { content.removeLast(2) }
            if let filename = header.components(separatedBy: "filename=\"").dropFirst().first?.components(separatedBy: "\"").first {
                files.append((filename, content))
            } else if header.contains("name=\"token\"") {
                token = String(decoding: content, as: UTF8.self)
            }
        }
        guard token == Self.validToken else {
            return response(Data(#"{"error":"Invalid token","errorcode":"invalidtoken"}"#.utf8), url, "application/json")
        }
        lock.withLock { uploadedFiles += files }
        let json = "[" + files.map { #"{"component":"user","filearea":"draft","itemid":\#(Self.draftItemId),"filename":"\#($0.0)"}"# }
            .joined(separator: ",") + "]"
        return response(Data(json.utf8), url, "application/json")
    }

    private func response(_ data: Data, _ url: URL, _ type: String) -> (Data, HTTPURLResponse) {
        (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": type])!)
    }
}

/// A database with a connected Moodle source, plus the pieces to sync it.
struct MoodleHarness {
    let database: UniDatabase
    let moodle = FakeMoodle()
    let clock = TestClock()
    let secrets = InMemorySecrets()

    init() throws {
        database = try UniDatabase.inMemory()
        try secrets.writeString(FakeMoodle.validToken, for: .moodleToken)
    }

    func sync(token: String = FakeMoodle.validToken) -> MoodleSync {
        let clock = clock
        return MoodleSync(database: database, client: MoodleClient(token: token, transport: moodle), now: { clock.now })
    }

    func items(_ kind: ItemKind) throws -> [UniItem] {
        try database.writer.read { db in
            try UniItem.filter(sql: "kind = ?", arguments: [kind.rawValue]).order(sql: "id").fetchAll(db)
        }
    }
}
