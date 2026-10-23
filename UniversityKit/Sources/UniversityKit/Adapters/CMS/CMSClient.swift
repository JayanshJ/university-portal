import Foundation

public enum CMSError: Error, Equatable {
    case http(status: Int, path: String)
    case tooManyRedirects(path: String)
}

/// Requests to cms.sic.saarland: at most one per `minimumInterval`, with its own cookie jar and
/// redirects followed here (the transport must not follow them or handle cookies itself).
public actor CMSClient {
    public static let siteURL = URL(string: "https://cms.sic.saarland")!

    public struct Page: Sendable {
        public var data: Data
        public var url: URL
        public var status: Int
        public var mimeType: String?

        public var body: String { String(decoding: data, as: UTF8.self) }
    }

    let transport: any HTTPTransport
    let siteURL: URL
    let minimumInterval: Duration
    public private(set) var cookieJar: CookieJar
    private var lastRequest: ContinuousClock.Instant?

    public init(transport: any HTTPTransport, siteURL: URL = CMSClient.siteURL,
                minimumInterval: Duration = .seconds(1), cookieJar: CookieJar = CookieJar()) {
        self.transport = transport
        self.siteURL = siteURL
        self.minimumInterval = minimumInterval
        self.cookieJar = cookieJar
    }

    public func setCookieJar(_ jar: CookieJar) {
        cookieJar = jar
    }

    /// GET a page and return its body; non-2xx is an error.
    public func get(_ path: String) async throws -> String {
        let page = try await fetch(path)
        guard (200..<300).contains(page.status) else { throw CMSError.http(status: page.status, path: path) }
        return page.body
    }

    /// GET with redirects followed; the returned page carries its final URL and status.
    public func fetch(_ path: String) async throws -> Page {
        try await send(URLRequest(url: url(path)), path: path)
    }

    /// POST a form (fields in order, names may repeat), following the redirect that usually answers it.
    public func post(_ path: String, fields: [(String, String)]) async throws -> Page {
        var request = URLRequest(url: url(path))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(FormEncoding.encode(fields).utf8)
        return try await send(request, path: path)
    }

    public nonisolated func url(_ path: String) -> URL {
        (URL(string: path, relativeTo: siteURL) ?? siteURL.appending(path: path)).absoluteURL
    }

    private func send(_ first: URLRequest, path: String) async throws -> Page {
        var request = first
        for _ in 0..<10 {
            try await throttle()
            let url = request.url!
            request.setValue(cookieJar.header(for: url), forHTTPHeaderField: "Cookie")
            let (data, response) = try await transport.send(request)
            cookieJar.store(from: response, for: url)

            guard [301, 302, 303, 307, 308].contains(response.statusCode),
                  let location = response.value(forHTTPHeaderField: "Location"),
                  let next = URL(string: location, relativeTo: url)?.absoluteURL else {
                return Page(data: data, url: url, status: response.statusCode, mimeType: response.mimeType)
            }
            if [307, 308].contains(response.statusCode) {
                request.url = next
            } else {
                request = URLRequest(url: next)  // the form is not sent again
            }
        }
        throw CMSError.tooManyRedirects(path: path)
    }

    private func throttle() async throws {
        if let lastRequest {
            let wait = lastRequest.advanced(by: minimumInterval) - .now
            if wait > .zero { try await Task.sleep(for: wait) }
        }
        lastRequest = .now
    }
}
