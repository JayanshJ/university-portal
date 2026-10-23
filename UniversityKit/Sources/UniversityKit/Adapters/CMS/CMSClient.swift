import Foundation

public enum CMSError: Error, Equatable {
    case http(status: Int, path: String)
}

/// Plain GETs against cms.sic.saarland, at most one request per `minimumInterval`.
public actor CMSClient {
    public static let siteURL = URL(string: "https://cms.sic.saarland")!

    let transport: any HTTPTransport
    let siteURL: URL
    let minimumInterval: Duration
    private var lastRequest: ContinuousClock.Instant?

    public init(transport: any HTTPTransport, siteURL: URL = CMSClient.siteURL, minimumInterval: Duration = .seconds(1)) {
        self.transport = transport
        self.siteURL = siteURL
        self.minimumInterval = minimumInterval
    }

    public func get(_ path: String) async throws -> String {
        if let lastRequest {
            let wait = lastRequest.advanced(by: minimumInterval) - .now
            if wait > .zero { try await Task.sleep(for: wait) }
        }
        lastRequest = .now

        let (data, response) = try await transport.send(URLRequest(url: url(path)))
        guard (200..<300).contains(response.statusCode) else {
            throw CMSError.http(status: response.statusCode, path: path)
        }
        return String(decoding: data, as: UTF8.self)
    }

    public nonisolated func url(_ path: String) -> URL {
        URL(string: path, relativeTo: siteURL)!.absoluteURL
    }
}
