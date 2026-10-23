import Foundation
import os

/// The in-app event layer: every sync run publishes what it created or changed, and any number of
/// listeners (views, notifications later) can follow along.
public final class UniEventHub: Sendable {
    private let listeners = OSAllocatedUnfairLock(initialState: [UUID: AsyncStream<UniEvent>.Continuation]())

    public init() {}

    /// A stream of every event published from now on, until the stream is dropped.
    public func events() -> AsyncStream<UniEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<UniEvent>.makeStream(bufferingPolicy: .bufferingNewest(500))
        listeners.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            _ = self?.listeners.withLock { $0.removeValue(forKey: id) }
        }
        return stream
    }

    public func publish(_ events: [UniEvent]) {
        guard !events.isEmpty else { return }
        let current = listeners.withLock { Array($0.values) }
        for continuation in current {
            events.forEach { continuation.yield($0) }
        }
    }
}
