import Foundation

public enum MoodleError: Error, Equatable, Sendable {
    /// The token is dead: reconnect needed.
    case invalidToken
    /// Moodle answered with an exception (HTTP 200 with `exception` and `errorcode`).
    case moodle(errorcode: String, message: String)
    case http(status: Int)
    case unexpectedResponse(String)
}

public enum MoodleParameter: Sendable {
    case value(String, String)
    case array(String, [String])

    public static func int(_ name: String, _ value: Int) -> MoodleParameter {
        .value(name, String(value))
    }

    public static func ints(_ name: String, _ values: [Int]) -> MoodleParameter {
        .array(name, values.map(String.init))
    }

    var fields: [(String, String)] {
        switch self {
        case let .value(name, value):
            [(name, value)]
        case let .array(name, values):
            values.enumerated().map { ("\(name)[\($0.offset)]", $0.element) }
        }
    }
}

/// The official mobile web service (`webservice/rest/server.php`), authenticated by token only.
public struct MoodleClient: Sendable {
    public static let siteURL = URL(string: "https://moodle.uni-saarland.de")!

    let token: String
    let transport: any HTTPTransport
    let siteURL: URL

    public init(token: String, transport: any HTTPTransport, siteURL: URL = Self.siteURL) {
        self.token = token
        self.transport = transport
        self.siteURL = siteURL
    }

    public func call<Response: Decodable>(
        _ function: String, _ parameters: [MoodleParameter] = [], as type: Response.Type = Response.self
    ) async throws -> Response {
        var request = URLRequest(url: siteURL.appending(path: "webservice/rest/server.php"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let fields = [("wstoken", token), ("wsfunction", function), ("moodlewsrestformat", "json")]
            + parameters.flatMap(\.fields)
        request.httpBody = Data(FormEncoding.encode(fields).utf8)

        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw MoodleError.http(status: response.statusCode)
        }
        if let failure = try? JSONDecoder().decode(MoodleException.self, from: data) {
            throw failure.error
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw MoodleError.unexpectedResponse("\(function): \(error)")
        }
    }

    /// Downloads a `webservice/pluginfile.php` URL. The token is added here and never stored with the URL.
    public func download(_ fileURL: String) async throws -> (data: Data, mimetype: String?) {
        guard var components = URLComponents(string: fileURL) else {
            throw MoodleError.unexpectedResponse("bad file URL")
        }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "token", value: token)]
        guard let url = components.url else { throw MoodleError.unexpectedResponse("bad file URL") }

        let (data, response) = try await transport.send(URLRequest(url: url))
        guard (200..<300).contains(response.statusCode) else {
            throw MoodleError.http(status: response.statusCode)
        }
        let mimetype = response.mimeType
        // A dead token comes back as a JSON exception instead of the file.
        if mimetype == "application/json", let failure = try? JSONDecoder().decode(MoodleException.self, from: data) {
            throw failure.error
        }
        return (data, mimetype)
    }
}

struct MoodleException: Decodable {
    var exception: String
    var errorcode: String
    var message: String?

    var error: MoodleError {
        errorcode == "invalidtoken"
            ? .invalidToken
            : .moodle(errorcode: errorcode, message: message ?? exception)
    }
}
