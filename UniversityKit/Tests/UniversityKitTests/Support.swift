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

    var calls: [String] { lock.withLock { log } }
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
            return response(Self.pdfBytes, url, "application/pdf")
        }

        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        let fields = Dictionary(body.split(separator: "&").map { pair -> (String, String) in
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            return (parts[0], parts.count > 1 ? parts[1] : "")
        }, uniquingKeysWith: { first, _ in first })
        let function = fields["wsfunction"] ?? ""
        lock.withLock { log.append(function) }

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
