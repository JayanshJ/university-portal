import Foundation

/// Sends requests for the adapters. Tests swap in a stub; the app uses `URLSessionTransport`.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

extension URLSessionTransport {
    /// For `CMSClient`: no cookie handling and no automatic redirects, so the client sees every
    /// response (and its `Set-Cookie`) itself.
    public static func manualRedirectsAndCookies() -> URLSessionTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSessionTransport(session: URLSession(
            configuration: configuration, delegate: NoRedirects(), delegateQueue: nil))
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil  // hand the 3xx back to the caller
    }
}

enum FormEncoding {
    private static let allowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// `application/x-www-form-urlencoded`, keeping field order.
    static func encode(_ fields: [(String, String)]) -> String {
        fields.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
    }

    static func escape(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
}

enum HTMLText {
    private static let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}"]

    /// Decodes the entities Moodle leaves in names, e.g. `Deskriptive&amp;WR` → `Deskriptive&WR`.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            result += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            if let semi = after.prefix(10).firstIndex(of: ";"),
               let decoded = decodeEntity(String(after[..<semi])) {
                result += decoded
                rest = after[after.index(after: semi)...]
            } else {
                result += "&"
                rest = after
            }
        }
        return result + rest
    }

    private static func decodeEntity(_ name: String) -> String? {
        if let value = named[name] { return value }
        guard name.hasPrefix("#") else { return nil }
        let digits = name.dropFirst()
        let code = digits.lowercased().hasPrefix("x")
            ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
        return code.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
    }
}
