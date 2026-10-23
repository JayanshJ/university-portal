import Foundation
import Security
import Testing
@testable import UniversityKit

/// A test RSA key that signs ID tokens like OpenAI's issuer.
struct TestSigner {
    let privateKey: SecKey
    let publicDER: Data

    init() {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, nil)!
        publicDER = SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(privateKey)!, nil)! as Data
    }

    func idToken(clientId: String, nonce: String?, subject: String = "user-123", email: String = "student@uni-saarland.de",
                 expires: Date = .now.addingTimeInterval(3600), issuer: String = ChatGPTAuth.issuer) -> String {
        let header = Base64URL.encode(try! JSONSerialization.data(withJSONObject: ["alg": "RS256", "kid": "test-key", "typ": "JWT"]))
        var claims: [String: Any] = ["iss": issuer, "aud": [clientId], "sub": subject, "email": email,
                                     "exp": expires.timeIntervalSince1970, "iat": Date.now.timeIntervalSince1970]
        if let nonce { claims["nonce"] = nonce }
        let payload = Base64URL.encode(try! JSONSerialization.data(withJSONObject: claims))
        let signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256,
                                              Data("\(header).\(payload)".utf8) as CFData, nil)! as Data
        return "\(header).\(payload).\(Base64URL.encode(signature))"
    }

    var verifier: IDTokenVerifier {
        let der = publicDER
        return IDTokenVerifier(issuer: ChatGPTAuth.issuer) { kid in kid == "test-key" ? der : nil }
    }
}

/// OpenAI's auth server and API, as far as the app uses them.
final class FakeOpenAI: HTTPTransport, StreamingTransport, @unchecked Sendable {
    let signer = TestSigner()
    private let lock = NSLock()
    private var nonces: [String: String] = [:]  // code → nonce from the authorize URL
    private var log: [(path: String, form: [String: String])] = []
    var issuedClientId = "oaiapp_test"
    var grantedScope = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    var refreshError: String?
    var refreshCount = 0
    var responseLines: [String] = []
    var responseStatus = 200
    var responseStatuses: [Int] = []  // per call, overrides responseStatus
    private(set) var responseRequests: [[String: Any]] = []
    private(set) var authorizations: [String] = []

    var requests: [(path: String, form: [String: String])] { lock.withLock { log } }

    func remember(code: String, nonce: String) { lock.withLock { nonces[code] = nonce } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let form = Dictionary(String(decoding: request.httpBody ?? Data(), as: UTF8.self).split(separator: "&").map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            return (parts[0], parts.count > 1 ? parts[1] : "")
        }, uniquingKeysWith: { a, _ in a })
        lock.withLock {
            log.append((url.path, form))
            if let auth = request.value(forHTTPHeaderField: "Authorization") { authorizations.append(auth) }
        }

        switch url.path {
        case "/.well-known/openid-configuration":
            return json(["revocation_endpoint": "https://auth.openai.com/oauth/revoke", "jwks_uri": "https://auth.openai.com/jwks"], url)
        case "/oauth/revoke":
            return (Data(), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        case "/api/accounts/oauth/token" where form["grant_type"] == "authorization_code":
            let nonce = lock.withLock { nonces[form["code"] ?? ""] }
            return json(["access_token": "access-1", "refresh_token": "refresh-1", "token_type": "Bearer", "expires_in": 3600,
                         "scope": grantedScope, "id_token": signer.idToken(clientId: form["client_id"]!, nonce: nonce)], url)
        case "/api/accounts/oauth/token" where form["grant_type"] == "refresh_token":
            if let refreshError { return json(["error": refreshError], url, status: 400) }
            let count = lock.withLock { refreshCount += 1; return refreshCount }
            return json(["access_token": "access-\(count + 1)", "refresh_token": "refresh-\(count + 1)",
                         "expires_in": 3600, "scope": grantedScope], url)
        case "/v1/models":
            return json(["models": [
                ["slug": "gpt-6.1-sol", "display_name": "GPT-6.1 Sol", "visibility": "list"],
                ["slug": "internal-x", "display_name": "Hidden", "visibility": "hide"],
                ["slug": "gpt-6.1-mini", "display_name": "GPT-6.1 mini", "visibility": "list"],
            ]], url)
        default:
            return json(["error": "not found"], url, status: 404)
        }
    }

    func lines(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, Error>) {
        let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
        let status: Int = lock.withLock {
            responseRequests.append(body)
            if let auth = request.value(forHTTPHeaderField: "Authorization") { authorizations.append(auth) }
            return responseStatuses.isEmpty ? responseStatus : responseStatuses.removeFirst()
        }
        let lines = status == 200 ? responseLines : [#"{"error":{"code":"\#(status == 429 ? "subscription_sharing_usage_limit_exceeded" : status == 401 ? "token_expired" : "boom")","message":"x"}}"#]
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (response, AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        })
    }

    private func json(_ object: Any, _ url: URL, status: Int = 200) -> (Data, HTTPURLResponse) {
        (try! JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

/// Plays the browser: reads the authorize URL, then calls the loopback redirect like OpenAI would.
func browser(_ openai: FakeOpenAI, clientIdInCallback: @escaping @Sendable (String) -> String? = { _ in "oaiapp_test" },
             error: String? = nil, wrongState: Bool = false, opened: @escaping @Sendable (URLComponents) -> Void = { _ in })
    -> @Sendable (URL) -> Void {
    { url in
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        opened(components)
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let code = "code-\(UUID().uuidString)"
        openai.remember(code: code, nonce: query["nonce"]!)
        var callback = URLComponents(string: query["redirect_uri"]!)!
        var items = [URLQueryItem(name: "state", value: wrongState ? "forged" : query["state"])]
        if let error { items.append(URLQueryItem(name: "error", value: error)) } else { items.append(URLQueryItem(name: "code", value: code)) }
        if let issued = clientIdInCallback(query["client_id"]!) { items.append(URLQueryItem(name: "client_id", value: issued)) }
        callback.queryItems = items
        Task { _ = try? await URLSession.shared.data(from: callback.url!) }
    }
}

@Suite(.serialized) struct ChatGPTAuthTests {
    func auth(_ openai: FakeOpenAI, secrets: InMemorySecrets = InMemorySecrets(), now: @escaping @Sendable () -> Date = { .now },
              open: @escaping @Sendable (URL) -> Void) -> ChatGPTAuth {
        ChatGPTAuth(secrets: secrets, transport: openai, openBrowser: open, now: now, verifier: openai.signer.verifier)
    }

    @Test func firstSignInRegistersAndStoresVerifiedCredentials() async throws {
        let openai = FakeOpenAI()
        let seen = Locked<URLComponents?>(nil)
        let secrets = InMemorySecrets()
        let chatgpt = auth(openai, secrets: secrets, open: browser(openai, opened: { seen.set($0) }))

        let credentials = try await chatgpt.signIn()

        #expect(credentials.clientId == "oaiapp_test")
        #expect(credentials.email == "student@uni-saarland.de")
        #expect(credentials.canUsePlan)
        #expect(try await chatgpt.accessToken() == "access-1")
        let query = Dictionary(uniqueKeysWithValues: (seen.get()?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(seen.get()?.host == "auth.openai.com")
        #expect(seen.get()?.path == "/api/accounts/authorize")
        #expect(query["client_id"] == "dynamic_agent_client")
        #expect(query["agent_name_hint"] == "University Portal")
        #expect(query["ext_agent_host_id"]?.hasPrefix("urn:uuid:") == true)
        #expect(query["scope"] == "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct")
        #expect(query["resource"] == "https://api.openai.com/v1")
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["redirect_uri"]?.hasPrefix("http://127.0.0.1:") == true)
        #expect(query["redirect_uri"]?.hasSuffix("/auth/callback") == true)
        // The exchange used the issued client, the PKCE verifier and the same redirect URI.
        let exchange = try #require(openai.requests.first { $0.form["grant_type"] == "authorization_code" })
        #expect(exchange.form["client_id"] == "oaiapp_test")
        #expect(exchange.form["redirect_uri"] == query["redirect_uri"])
        #expect(ChatGPTAuth.codeChallenge(exchange.form["code_verifier"]!) == query["code_challenge"])
        #expect(exchange.form["resource"] == "https://api.openai.com/v1")
        // Tokens only in the secret store.
        #expect(try secrets.read(.chatgptCredentials) != nil)
    }

    @Test func secondSignInReusesTheIssuedClient() async throws {
        let openai = FakeOpenAI()
        let secrets = InMemorySecrets()
        try await auth(openai, secrets: secrets, open: browser(openai)).signIn()
        let seen = Locked<URLComponents?>(nil)

        try await auth(openai, secrets: secrets, open: browser(openai, clientIdInCallback: { _ in nil }, opened: { seen.set($0) })).signIn()

        let query = Dictionary(uniqueKeysWithValues: (seen.get()?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(query["client_id"] == "oaiapp_test")
        #expect(query["agent_name_hint"] == nil)
        #expect(query["id_token_hint"] != nil)
        #expect(query["login_hint"] == "student@uni-saarland.de")
    }

    @Test func forgedStateDeniedConsentAndClientSwapAreRejected() async throws {
        let openai = FakeOpenAI()
        await #expect(throws: ChatGPTError.stateMismatch) {
            try await auth(openai, open: browser(openai, wrongState: true)).signIn()
        }
        await #expect(throws: ChatGPTError.accessDenied) {
            try await auth(openai, open: browser(openai, error: "access_denied")).signIn()
        }
        await #expect(throws: ChatGPTError.registrationIncomplete) {
            try await auth(openai, open: browser(openai, clientIdInCallback: { _ in nil })).signIn()
        }
        let secrets = InMemorySecrets()
        try await auth(openai, secrets: secrets, open: browser(openai)).signIn()
        await #expect(throws: ChatGPTError.clientMismatch) {
            try await auth(openai, secrets: secrets, open: browser(openai, clientIdInCallback: { _ in "oaiapp_other" })).signIn()
        }
    }

    @Test func declinedPlanUsageKeepsSignInButBlocksRequests() async throws {
        let openai = FakeOpenAI()
        openai.grantedScope = "openid profile email offline_access"
        let chatgpt = auth(openai, open: browser(openai))

        let credentials = try await chatgpt.signIn()

        #expect(!credentials.canUsePlan)
        await #expect(throws: ChatGPTError.planUsageNotGranted) { try await chatgpt.accessToken() }
    }

    @Test func expiringTokenIsRefreshedOnceAndRotated() async throws {
        let openai = FakeOpenAI()
        let clock = TestClock(.now)
        let secrets = InMemorySecrets()
        let chatgpt = auth(openai, secrets: secrets, now: { clock.now }, open: browser(openai))
        try await chatgpt.signIn()
        clock.advance(hours: 0.95)  // 3 minutes left: inside the 5-minute margin

        async let a = chatgpt.accessToken()
        async let b = chatgpt.accessToken()
        let tokens = try await [a, b]

        #expect(tokens == ["access-2", "access-2"])
        #expect(openai.refreshCount == 1)  // serialized
        let refresh = try #require(openai.requests.first { $0.form["grant_type"] == "refresh_token" })
        #expect(refresh.form["refresh_token"] == "refresh-1")
        #expect(refresh.form["client_id"] == "oaiapp_test")
        #expect(refresh.form["scope"] == nil)
        #expect(await chatgpt.credentials()?.refreshToken == "refresh-2")
    }

    @Test func revokedRefreshTokenSignsOut() async throws {
        let openai = FakeOpenAI()
        let clock = TestClock(.now)
        let chatgpt = auth(openai, now: { clock.now }, open: browser(openai))
        try await chatgpt.signIn()
        clock.advance(hours: 2)
        openai.refreshError = "refresh_token_reused"

        await #expect(throws: ChatGPTError.signInExpired) { try await chatgpt.accessToken() }
        #expect(await chatgpt.credentials() == nil)
    }

    @Test func signOutRevokesAndForgetsTokensButKeepsRegistration() async throws {
        let openai = FakeOpenAI()
        let secrets = InMemorySecrets()
        let chatgpt = auth(openai, secrets: secrets, open: browser(openai))
        try await chatgpt.signIn()

        #expect(await chatgpt.signOut())

        let revoke = try #require(openai.requests.first { $0.path == "/oauth/revoke" })
        #expect(revoke.form["token"] == "refresh-1")
        #expect(revoke.form["token_type_hint"] == "refresh_token")
        #expect(try secrets.read(.chatgptCredentials) == nil)
        #expect(try secrets.read(.chatgptRegistration) != nil)
    }
}

@Suite struct IDTokenTests {
    let signer = TestSigner()

    @Test func validTokenPasses() async throws {
        let claims = try await signer.verifier.verify(signer.idToken(clientId: "c", nonce: "n"), clientId: "c", nonce: "n")
        #expect(claims.subject == "user-123")
        #expect(claims.email == "student@uni-saarland.de")
    }

    @Test func badTokensFail() async throws {
        await #expect(throws: IDTokenError.wrongAudience) {
            try await signer.verifier.verify(signer.idToken(clientId: "other", nonce: "n"), clientId: "c", nonce: "n")
        }
        await #expect(throws: IDTokenError.wrongNonce) {
            try await signer.verifier.verify(signer.idToken(clientId: "c", nonce: "x"), clientId: "c", nonce: "n")
        }
        await #expect(throws: IDTokenError.expired) {
            try await signer.verifier.verify(signer.idToken(clientId: "c", nonce: "n", expires: .now.addingTimeInterval(-600)), clientId: "c", nonce: "n")
        }
        await #expect(throws: IDTokenError.wrongIssuer) {
            try await signer.verifier.verify(signer.idToken(clientId: "c", nonce: "n", issuer: "https://evil.example"), clientId: "c", nonce: "n")
        }
        let token = signer.idToken(clientId: "c", nonce: "n")
        let tampered = token.split(separator: ".").enumerated().map { $0.offset == 1 ? Base64URL.encode(Data(#"{"sub":"admin","aud":["c"],"iss":"https://auth.openai.com","exp":9999999999,"nonce":"n"}"#.utf8)) : String($0.element) }.joined(separator: ".")
        await #expect(throws: IDTokenError.badSignature) {
            try await signer.verifier.verify(tampered, clientId: "c", nonce: "n")
        }
        let otherSigner = TestSigner()
        await #expect(throws: IDTokenError.badSignature) {
            try await signer.verifier.verify(otherSigner.idToken(clientId: "c", nonce: "n"), clientId: "c", nonce: "n")
        }
    }

    @Test func jwkModulusAndExponentRebuildTheSameKey() throws {
        // Split the test key's PKCS#1 DER into n and e, then rebuild it from those (as from a JWKS).
        let der = [UInt8](signer.publicDER)
        func readLength(_ i: inout Int) -> Int {
            let first = Int(der[i]); i += 1
            guard first & 0x80 != 0 else { return first }
            var length = 0
            for _ in 0..<(first & 0x7F) { length = length << 8 | Int(der[i]); i += 1 }
            return length
        }
        var i = 1
        _ = readLength(&i)
        i += 1; let nLength = readLength(&i); let n = Data(der[i..<(i + nLength)]); i += nLength
        i += 1; let eLength = readLength(&i); let e = Data(der[i..<(i + eLength)])

        #expect(RSAPublicKey.der(modulus: n, exponent: e) == signer.publicDER)
        #expect(RSAPublicKey.make(der: RSAPublicKey.der(modulus: n.drop { $0 == 0 }, exponent: e)) != nil)
    }
}

@Suite struct ResponsesClientTests {
    func client(_ openai: FakeOpenAI) async throws -> ResponsesClient {
        let auth = ChatGPTAuth(secrets: InMemorySecrets(), transport: openai, openBrowser: browser(openai),
                               now: { .now }, verifier: openai.signer.verifier)
        try await auth.signIn()
        return ResponsesClient(auth: auth, transport: openai, streaming: openai)
    }

    static let okLines = [
        "event: response.created", #"data: {"type":"response.created"}"#, "",
        #"data: {"type":"response.output_text.delta","delta":"Short loops "}"#,
        #"data: {"type":"response.output_text.delta","delta":"break it [2]."}"#,
        #"data: {"type":"response.completed","response":{"status":"completed"}}"#,
    ]

    @Test func streamsTextAndSendsTheRequiredBody() async throws {
        let openai = FakeOpenAI()
        openai.responseLines = Self.okLines
        let client = try await client(openai)

        let text = try await client.complete(model: "gpt-6.1-sol", instructions: "Be brief.",
                                             input: [ChatMessage(role: .user, content: "Why?")])

        #expect(text == "Short loops break it [2].")
        let body = try #require(openai.responseRequests.first)
        #expect(body["store"] as? Bool == false)
        #expect(body["stream"] as? Bool == true)
        #expect(body["model"] as? String == "gpt-6.1-sol")
        #expect(body["instructions"] as? String == "Be brief.")
        for forbidden in ["temperature", "max_output_tokens", "previous_response_id", "top_p", "user", "metadata"] {
            #expect(body[forbidden] == nil)
        }
        #expect(openai.authorizations.last == "Bearer access-1")
    }

    @Test func streamWithoutCompletionFails() async throws {
        let openai = FakeOpenAI()
        openai.responseLines = Array(Self.okLines.dropLast())
        let client = try await client(openai)
        await #expect(throws: ChatGPTError.self) {
            _ = try await client.complete(model: "m", instructions: "", input: [])
        }
    }

    @Test func usageErrorsAreMapped() async throws {
        let openai = FakeOpenAI()
        let client = try await client(openai)

        openai.responseStatus = 429
        await #expect(throws: ChatGPTError.usageLimitReached) { _ = try await client.complete(model: "m", instructions: "", input: []) }

        openai.responseStatus = 200
        openai.responseLines = [#"data: {"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_unavailable"}}}"#]
        await #expect(throws: ChatGPTError.usageUnavailable) { _ = try await client.complete(model: "m", instructions: "", input: []) }

        openai.responseLines = [#"data: {"type":"response.failed","response":{"error":{"code":"subscription_sharing_user_not_eligible"}}}"#]
        await #expect(throws: ChatGPTError.notEligible) { _ = try await client.complete(model: "m", instructions: "", input: []) }
    }

    @Test func unauthorizedRequestRefreshesOnceAndRetries() async throws {
        let openai = FakeOpenAI()
        openai.responseLines = Self.okLines
        openai.responseStatuses = [401, 200]
        let client = try await client(openai)

        let text = try await client.complete(model: "m", instructions: "", input: [])

        #expect(text == "Short loops break it [2].")
        #expect(openai.refreshCount == 1)
        #expect(openai.authorizations.suffix(2) == ["Bearer access-1", "Bearer access-2"])
    }

    @Test func modelListKeepsListedModelsInOrder() async throws {
        let openai = FakeOpenAI()
        let models = try await client(openai).models()
        #expect(models.map(\.slug) == ["gpt-6.1-sol", "gpt-6.1-mini"])
        #expect(models.first?.displayName == "GPT-6.1 Sol")
    }
}

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func set(_ newValue: Value) { lock.withLock { value = newValue } }
}
