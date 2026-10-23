import CryptoKit
import Foundation

/// A signed-in ChatGPT session. Stored in the Keychain only.
public struct ChatGPTCredentials: Codable, Sendable, Equatable {
    public var email: String?
    public var subject: String
    public var clientId: String
    public var accessToken: String
    public var refreshToken: String
    public var idToken: String
    public var expiresAt: Date
    public var scopes: [String]
    public var savedAt: Date

    /// Requests may use the ChatGPT plan only when the user granted this scope.
    public var canUsePlan: Bool { scopes.contains(ChatGPTAuth.planScope) }
}

/// The app's registration with OpenAI: kept across sign-outs so later sign-ins reuse the issued client.
struct ChatGPTRegistration: Codable, Sendable, Equatable {
    var hostId: String
    var clientId: String?
    var idToken: String?
    var email: String?
}

public enum ChatGPTError: Error, Equatable {
    case notSignedIn
    case accessDenied
    case stateMismatch
    case registrationIncomplete
    case clientMismatch
    case planUsageNotGranted
    case signInExpired
    case usageLimitReached
    case notEligible
    case usageUnavailable
    case incomplete(String)
    case server(String)
}

/// "Continue with ChatGPT" for open-source and local apps (developers.openai.com/siwc), so requests
/// run on the user's ChatGPT plan: dynamic registration, PKCE, a loopback redirect on 127.0.0.1,
/// ID-token verification, refresh with rotation, and revocation on sign-out.
public actor ChatGPTAuth {
    public static let issuer = "https://auth.openai.com"
    public static let resource = "https://api.openai.com/v1"
    public static let planScope = "chatgpt.tokens.use.direct"
    static let scopes = "openid profile email offline_access resource.invoke \(planScope)"
    static let appName = "University Portal"
    static let refreshMargin: TimeInterval = 5 * 60

    let secrets: any SecretStore
    let transport: any HTTPTransport
    let openBrowser: @Sendable (URL) -> Void
    let now: @Sendable () -> Date
    let verifier: IDTokenVerifier

    private var refreshing: Task<ChatGPTCredentials, Error>?

    private static let log = Log(category: "chatgpt")

    public init(secrets: any SecretStore, transport: any HTTPTransport,
                openBrowser: @escaping @Sendable (URL) -> Void, now: @escaping @Sendable () -> Date = { .now }) {
        self.secrets = secrets
        self.transport = transport
        self.openBrowser = openBrowser
        self.now = now
        let keys = KeyCache(transport: transport)
        self.verifier = IDTokenVerifier(issuer: Self.issuer) { kid in try await keys.key(kid) }
    }

    init(secrets: any SecretStore, transport: any HTTPTransport, openBrowser: @escaping @Sendable (URL) -> Void,
         now: @escaping @Sendable () -> Date, verifier: IDTokenVerifier) {
        self.secrets = secrets
        self.transport = transport
        self.openBrowser = openBrowser
        self.now = now
        self.verifier = verifier
    }

    public func credentials() -> ChatGPTCredentials? {
        (try? secrets.read(.chatgptCredentials)).flatMap { $0 }.flatMap { try? JSONDecoder().decode(ChatGPTCredentials.self, from: $0) }
    }

    // MARK: - Sign-in

    /// Opens the browser for consent and waits for the loopback redirect (up to five minutes).
    @discardableResult
    public func signIn() async throws -> ChatGPTCredentials {
        var registration = loadRegistration()
        let listener = try await LoopbackListener.start()
        defer { listener.stop() }

        let state = Self.randomToken(), nonce = Self.randomToken(), verifier = Self.randomToken()
        let url = Self.authorizeURL(registration: registration, redirectURI: listener.redirectURI, state: state,
                                    nonce: nonce, codeChallenge: Self.codeChallenge(verifier))
        openBrowser(url)

        let callback = try await listener.callback()
        guard callback["state"] == state else { throw ChatGPTError.stateMismatch }
        if callback["error"] != nil { throw ChatGPTError.accessDenied }
        guard let code = callback["code"] else { throw ChatGPTError.accessDenied }

        let issued = callback["client_id"].flatMap { $0 == "dynamic_agent_client" ? nil : $0 }
        let clientId: String
        if let saved = registration.clientId {
            if let issued, issued != saved { throw ChatGPTError.clientMismatch }
            clientId = saved
        } else {
            guard let issued else { throw ChatGPTError.registrationIncomplete }
            clientId = issued
        }
        registration.clientId = clientId
        try saveRegistration(registration)  // the client exists now, even if the exchange below fails

        let tokens = try await tokenRequest([
            ("grant_type", "authorization_code"), ("client_id", clientId), ("code", code),
            ("code_verifier", verifier), ("redirect_uri", listener.redirectURI), ("resource", Self.resource),
        ])
        guard let idToken = tokens.idToken else { throw ChatGPTError.server("No ID token in the token response") }
        let claims = try await self.verifier.verify(idToken, clientId: clientId, nonce: nonce, now: now())

        let credentials = ChatGPTCredentials(
            email: claims.email, subject: claims.subject, clientId: clientId,
            accessToken: tokens.accessToken, refreshToken: tokens.refreshToken ?? "", idToken: idToken,
            expiresAt: now().addingTimeInterval(tokens.expiresIn), scopes: tokens.scopes, savedAt: now())
        try save(credentials)
        registration.idToken = idToken
        registration.email = claims.email
        try saveRegistration(registration)
        Self.log.info("Signed in to ChatGPT; plan usage granted: \(credentials.canUsePlan)")
        return credentials
    }

    static func authorizeURL(registration: ChatGPTRegistration, redirectURI: String, state: String, nonce: String,
                             codeChallenge: String) -> URL {
        var items = [
            URLQueryItem(name: "client_id", value: registration.clientId ?? "dynamic_agent_client"),
            URLQueryItem(name: "ext_agent_host_id", value: registration.hostId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "resource", value: resource),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
        ]
        if registration.clientId == nil {
            items.append(URLQueryItem(name: "agent_name_hint", value: appName))
        } else {
            if let hint = registration.idToken { items.append(URLQueryItem(name: "id_token_hint", value: hint)) }
            if let email = registration.email { items.append(URLQueryItem(name: "login_hint", value: email)) }
        }
        var components = URLComponents(string: issuer + "/api/accounts/authorize")!
        components.queryItems = items
        // URLComponents leaves "+" and ":" alone; the spec asks for every value to be URL-encoded.
        components.percentEncodedQuery = items.map {
            "\($0.name)=\(FormEncoding.escape($0.value ?? ""))"
        }.joined(separator: "&")
        return components.url!
    }

    // MARK: - Tokens

    /// A valid access token, refreshed when it expires within five minutes. Refreshes are serialized.
    public func accessToken() async throws -> String {
        guard let credentials = credentials() else { throw ChatGPTError.notSignedIn }
        guard credentials.canUsePlan else { throw ChatGPTError.planUsageNotGranted }
        if credentials.expiresAt.timeIntervalSince(now()) > Self.refreshMargin { return credentials.accessToken }
        return try await refresh().accessToken
    }

    /// After a 401 on a request: refresh once and retry with the new token.
    public func refreshedAccessToken() async throws -> String {
        try await refresh().accessToken
    }

    private func refresh() async throws -> ChatGPTCredentials {
        if let refreshing { return try await refreshing.value }
        let task = Task { try await performRefresh() }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    private func performRefresh() async throws -> ChatGPTCredentials {
        guard var credentials = credentials() else { throw ChatGPTError.notSignedIn }
        do {
            let tokens = try await tokenRequest([
                ("grant_type", "refresh_token"), ("client_id", credentials.clientId),
                ("refresh_token", credentials.refreshToken), ("resource", Self.resource),
            ])
            credentials.accessToken = tokens.accessToken
            credentials.refreshToken = tokens.refreshToken ?? credentials.refreshToken
            if let idToken = tokens.idToken { credentials.idToken = idToken }
            credentials.expiresAt = now().addingTimeInterval(tokens.expiresIn)
            if !tokens.scopes.isEmpty { credentials.scopes = tokens.scopes }
            credentials.savedAt = now()
            try save(credentials)
            return credentials
        } catch ChatGPTError.signInExpired {
            try? secrets.delete(.chatgptCredentials)
            throw ChatGPTError.signInExpired
        }
    }

    struct TokenResponse {
        var accessToken: String
        var refreshToken: String?
        var idToken: String?
        var expiresIn: TimeInterval
        var scopes: [String]
    }

    private func tokenRequest(_ fields: [(String, String)]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: Self.issuer + "/api/accounts/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(FormEncoding.encode(fields).utf8)
        let (data, response) = try await transport.send(request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(response.statusCode), let access = json["access_token"] as? String else {
            let code = (json["error"] as? String) ?? ((json["error"] as? [String: Any])?["code"] as? String) ?? "http \(response.statusCode)"
            if Self.signInExpiredCodes.contains(code) { throw ChatGPTError.signInExpired }
            if response.statusCode >= 500 { throw ChatGPTError.usageUnavailable }
            throw ChatGPTError.server(code)
        }
        return TokenResponse(
            accessToken: access, refreshToken: json["refresh_token"] as? String, idToken: json["id_token"] as? String,
            expiresIn: (json["expires_in"] as? Double) ?? 3600,
            scopes: (json["scope"] as? String)?.split(separator: " ").map(String.init) ?? [])
    }

    static let signInExpiredCodes: Set<String> = [
        "invalid_grant", "token_expired", "refresh_token_expired", "refresh_token_invalidated",
        "refresh_token_reused", "invalid_refresh_token", "subscription_sharing_invalid_user",
    ]

    // MARK: - Sign-out

    /// Revokes the refresh token and forgets the session. Returns false when revocation wasn't confirmed
    /// (the local session is cleared anyway; the user can disconnect in ChatGPT settings).
    @discardableResult
    public func signOut() async -> Bool {
        defer { try? secrets.delete(.chatgptCredentials) }
        guard let credentials = credentials() else { return true }
        do {
            let (config, _) = try await transport.send(URLRequest(url: URL(string: Self.issuer + "/.well-known/openid-configuration")!))
            let json = try JSONSerialization.jsonObject(with: config) as? [String: Any]
            guard let endpoint = (json?["revocation_endpoint"] as? String).flatMap(URL.init(string:)) else { return false }
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(FormEncoding.encode([
                ("token", credentials.refreshToken), ("token_type_hint", "refresh_token"), ("client_id", credentials.clientId),
            ]).utf8)
            let (_, response) = try await transport.send(request)
            return response.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Storage and helpers

    private func save(_ credentials: ChatGPTCredentials) throws {
        try secrets.write(try JSONEncoder().encode(credentials), for: .chatgptCredentials)
    }

    private func loadRegistration() -> ChatGPTRegistration {
        if let data = (try? secrets.read(.chatgptRegistration)).flatMap({ $0 }),
           let registration = try? JSONDecoder().decode(ChatGPTRegistration.self, from: data) {
            return registration
        }
        return ChatGPTRegistration(hostId: "urn:uuid:" + UUID().uuidString.lowercased())
    }

    private func saveRegistration(_ registration: ChatGPTRegistration) throws {
        try secrets.write(try JSONEncoder().encode(registration), for: .chatgptRegistration)
    }

    static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Base64URL.encode(Data(bytes))
    }

    static func codeChallenge(_ verifier: String) -> String {
        Base64URL.encode(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
}

/// OpenAI's signing keys, fetched once from the JWKS and cached.
actor KeyCache {
    let transport: any HTTPTransport
    private var keys: [String: Data] = [:]

    init(transport: any HTTPTransport) {
        self.transport = transport
    }

    func key(_ kid: String) async throws -> Data? {
        if let key = keys[kid] { return key }
        let (config, _) = try await transport.send(URLRequest(url: URL(string: ChatGPTAuth.issuer + "/.well-known/openid-configuration")!))
        let jwksURL = ((try JSONSerialization.jsonObject(with: config) as? [String: Any])?["jwks_uri"] as? String)
            .flatMap(URL.init(string:)) ?? URL(string: ChatGPTAuth.issuer + "/.well-known/jwks.json")!
        let (data, _) = try await transport.send(URLRequest(url: jwksURL))
        let entries = ((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["keys"] as? [[String: Any]]) ?? []
        for entry in entries where entry["kty"] as? String == "RSA" {
            guard let id = entry["kid"] as? String, let n = (entry["n"] as? String).flatMap(Base64URL.decode),
                  let e = (entry["e"] as? String).flatMap(Base64URL.decode) else { continue }
            keys[id] = RSAPublicKey.der(modulus: n, exponent: e)
        }
        return keys[kid]
    }
}
