import Foundation
import Network

/// A one-shot HTTP listener on 127.0.0.1 that receives the OAuth redirect from the browser.
final class LoopbackListener: @unchecked Sendable {
    enum ListenerError: Error, Equatable {
        case couldNotListen
        case timedOut
    }

    let port: UInt16
    private let listener: NWListener
    private let queue = DispatchQueue(label: "app.jayansh.UniversityPortal.loopback")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var pending: Result<[String: String], Error>?

    var redirectURI: String { "http://127.0.0.1:\(port)/auth/callback" }

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    /// Listens on the first free port of `ports` (0 = any free port).
    static func start(ports: [UInt16] = [1455, 0]) async throws -> LoopbackListener {
        for port in ports {
            if let listener = try? await start(port: port) { return listener }
        }
        throw ListenerError.couldNotListen
    }

    private static func start(port: UInt16) async throws -> LoopbackListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true
        let nwListener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "app.jayansh.UniversityPortal.loopback.start")
        let boundPort: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = OnceFlag()
            nwListener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume(returning: nwListener.port?.rawValue ?? port) }
                case .failed(let error):
                    if once.claim() { continuation.resume(throwing: error) }
                    nwListener.cancel()
                case .cancelled:
                    if once.claim() { continuation.resume(throwing: ListenerError.couldNotListen) }
                default: break
                }
            }
            nwListener.newConnectionHandler = { $0.cancel() }  // replaced below once ready
            nwListener.start(queue: queue)
        }
        let listener = LoopbackListener(listener: nwListener, port: boundPort)
        nwListener.newConnectionHandler = { [weak listener] connection in listener?.handle(connection) }
        return listener
    }

    /// Waits for the browser to hit `/auth/callback` and returns its query parameters.
    func callback(timeout: Duration = .seconds(300)) async throws -> [String: String] {
        try await withThrowingTaskGroup(of: [String: String].self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    self.lock.lock()
                    if let pending = self.pending {
                        self.lock.unlock()
                        continuation.resume(with: pending)
                    } else {
                        self.continuation = continuation
                        self.lock.unlock()
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ListenerError.timedOut
            }
            defer { group.cancelAll() }
            let result = try await group.next()!
            return result
        }
    }

    func stop() {
        listener.cancel()
        deliver(.failure(CancellationError()))
    }

    private func deliver(_ result: Result<[String: String], Error>) {
        lock.lock()
        defer { lock.unlock() }
        if let continuation {
            self.continuation = nil
            continuation.resume(with: result)
        } else if pending == nil {
            pending = result
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8),
                  let line = request.split(separator: "\r\n").first else {
                connection.cancel()
                return
            }
            let parts = line.split(separator: " ")
            guard parts.count >= 2, let components = URLComponents(string: "http://127.0.0.1\(parts[1])"),
                  components.path == "/auth/callback" else {
                self.respond(connection, status: "404 Not Found", body: "Not found")
                return
            }
            var query: [String: String] = [:]
            for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
            let ok = query["error"] == nil
            self.respond(connection, status: "200 OK", body: ok
                ? "<h2>Signed in to ChatGPT</h2><p>You can close this tab and return to University Portal.</p>"
                : "<h2>Sign-in was not completed</h2><p>You can close this tab and try again in University Portal.</p>")
            self.deliver(.success(query))
        }
    }

    private func respond(_ connection: NWConnection, status: String, body: String) {
        let html = """
            <!doctype html><html><head><meta charset="utf-8"><title>University Portal</title>
            <style>body{font:15px -apple-system,sans-serif;background:#0b0b0d;color:#ededef;display:grid;place-items:center;height:90vh;text-align:center}</style>
            </head><body><div>\(body)</div></body></html>
            """
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// True exactly once, across threads.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}
