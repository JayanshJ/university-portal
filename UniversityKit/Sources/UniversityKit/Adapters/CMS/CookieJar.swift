import Foundation

/// The CMS session cookies. Kept by the app (not URLSession) so that cookies set on redirect
/// responses, like the login's 302, are captured, and so the jar can be saved to the Keychain.
public struct CookieJar: Codable, Sendable, Equatable {
    struct Cookie: Codable, Sendable, Equatable {
        var name: String
        var value: String
        var domain: String
        var path: String
        var expires: Date?
        var secure: Bool
    }

    private(set) var cookies: [Cookie] = []

    public init() {}

    public var isEmpty: Bool { cookies.isEmpty }

    mutating func store(from response: HTTPURLResponse, for url: URL, now: Date = .now) {
        var fields: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String { fields[key] = value }
        }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: fields, for: url) {
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            cookies.removeAll { $0.name == cookie.name && $0.domain == domain && $0.path == cookie.path }
            if let expires = cookie.expiresDate, expires <= now { continue }  // a deletion
            cookies.append(Cookie(name: cookie.name, value: cookie.value, domain: domain, path: cookie.path,
                                  expires: cookie.expiresDate, secure: cookie.isSecure))
        }
    }

    /// The `Cookie` header for `url`, or nil when no cookie applies.
    func header(for url: URL, now: Date = .now) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let path = url.path.isEmpty ? "/" : url.path
        let matching = cookies.filter { cookie in
            (host == cookie.domain || host.hasSuffix("." + cookie.domain))
                && path.hasPrefix(cookie.path)
                && (!cookie.secure || url.scheme == "https")
                && (cookie.expires.map { $0 > now } ?? true)
        }
        return matching.isEmpty ? nil : matching.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
}
