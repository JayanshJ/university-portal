import Foundation

/// Line-by-line HTTP streaming (server-sent events). Tests swap in a stub.
public protocol StreamingTransport: Sendable {
    func lines(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, Error>)
}

public struct URLSessionStreamingTransport: StreamingTransport {
    let session: URLSession

    public init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    public func lines(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, Error>) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let stream = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (http, stream)
    }
}

public struct ChatGPTModel: Codable, Sendable, Hashable, Identifiable {
    public var slug: String
    public var displayName: String
    public var id: String { slug }

    public init(slug: String, displayName: String) {
        self.slug = slug
        self.displayName = displayName
    }
}

public struct ChatMessage: Sendable, Equatable {
    public enum Role: String, Sendable { case user, assistant }
    public var role: Role
    public var content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

/// The Responses API on the user's ChatGPT plan (`store: false`, `stream: true`, no sampling options,
/// system text in `instructions`), per developers.openai.com/siwc models-and-inference and preview limits.
public struct ResponsesClient: Sendable {
    static let base = URL(string: ChatGPTAuth.resource)!

    let auth: ChatGPTAuth
    let transport: any HTTPTransport
    let streaming: any StreamingTransport

    public init(auth: ChatGPTAuth, transport: any HTTPTransport, streaming: any StreamingTransport) {
        self.auth = auth
        self.transport = transport
        self.streaming = streaming
    }

    /// Models this account can use, in the server's order (only `visibility == "list"`).
    public func models() async throws -> [ChatGPTModel] {
        var request = URLRequest(url: Self.base.appending(path: "models"))
        request.setValue("Bearer \(try await auth.accessToken())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else { throw Self.error(status: response.statusCode, body: data) }
        let json = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let entries = (json["models"] as? [[String: Any]]) ?? (json["data"] as? [[String: Any]]) ?? []
        return entries.compactMap { entry in
            if let visibility = entry["visibility"] as? String, visibility != "list" { return nil }
            guard let slug = (entry["slug"] as? String) ?? (entry["id"] as? String) else { return nil }
            return ChatGPTModel(slug: slug, displayName: (entry["display_name"] as? String) ?? slug)
        }
    }

    /// Streams the answer text. Ends with an error unless the server sends `response.completed`.
    public func stream(model: String, instructions: String, input: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var lines: AsyncThrowingStream<String, Error>
                    var (response, stream) = try await send(model: model, instructions: instructions, input: input,
                                                            token: try await auth.accessToken())
                    if response.statusCode == 401 {
                        // Expired or revoked token: refresh once, then retry.
                        _ = try await Self.drain(stream)
                        (response, stream) = try await send(model: model, instructions: instructions, input: input,
                                                            token: try await auth.refreshedAccessToken())
                    }
                    lines = stream
                    guard (200..<300).contains(response.statusCode) else {
                        throw Self.error(status: response.statusCode, body: Data(try await Self.drain(lines).utf8))
                    }
                    var completed = false
                    for try await line in lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard payload != "[DONE]", let data = payload.data(using: .utf8),
                              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        switch event["type"] as? String {
                        case "response.output_text.delta":
                            if let delta = event["delta"] as? String { continuation.yield(delta) }
                        case "response.completed":
                            completed = true
                        case "response.failed", "error":
                            let error = ((event["response"] as? [String: Any])?["error"] as? [String: Any]) ?? (event["error"] as? [String: Any]) ?? event
                            throw Self.mapCode((error["code"] as? String) ?? "", message: error["message"] as? String)
                        case "response.incomplete":
                            let reason = (((event["response"] as? [String: Any])?["incomplete_details"]) as? [String: Any])?["reason"] as? String
                            throw ChatGPTError.incomplete(reason ?? "incomplete")
                        default:
                            break
                        }
                    }
                    guard completed else { throw ChatGPTError.incomplete("The answer stopped before it was complete.") }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The whole answer as one string (for short helper requests).
    public func complete(model: String, instructions: String, input: [ChatMessage]) async throws -> String {
        var text = ""
        for try await delta in stream(model: model, instructions: instructions, input: input) { text += delta }
        return text
    }

    private func send(model: String, instructions: String, input: [ChatMessage], token: String) async throws
        -> (HTTPURLResponse, AsyncThrowingStream<String, Error>) {
        var request = URLRequest(url: Self.base.appending(path: "responses"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.body(model: model, instructions: instructions, input: input))
        return try await streaming.lines(for: request)
    }

    static func body(model: String, instructions: String, input: [ChatMessage]) -> [String: Any] {
        [
            "model": model,
            "instructions": instructions,
            "input": input.map { ["role": $0.role.rawValue, "content": $0.content] },
            "store": false,
            "stream": true,
        ]
    }

    static func drain(_ lines: AsyncThrowingStream<String, Error>) async throws -> String {
        var text = ""
        for try await line in lines { text += line + "\n" }
        return text
    }

    static func error(status: Int, body: Data) -> Error {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let error = (json?["error"] as? [String: Any]) ?? (json?["detail"] as? [String: Any]) ?? [:]
        let code = (error["code"] as? String) ?? (json?["error"] as? String) ?? ""
        if code.isEmpty {
            switch status {
            case 401: return ChatGPTError.signInExpired
            case 429: return ChatGPTError.usageLimitReached
            case 503: return ChatGPTError.usageUnavailable
            default: return ChatGPTError.server("HTTP \(status)")
            }
        }
        return mapCode(code, message: error["message"] as? String)
    }

    static func mapCode(_ code: String, message: String?) -> ChatGPTError {
        switch code {
        case "subscription_sharing_usage_limit_exceeded": .usageLimitReached
        case "subscription_sharing_user_not_eligible": .notEligible
        case "subscription_sharing_usage_unavailable": .usageUnavailable
        case _ where ChatGPTAuth.signInExpiredCodes.contains(code): .signInExpired
        default: .server(message.map { "\(code): \($0)" } ?? code)
        }
    }
}
