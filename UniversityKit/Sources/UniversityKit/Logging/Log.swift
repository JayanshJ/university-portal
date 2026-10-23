import os

/// The only way the app logs. Every message is redacted before it reaches `os.Logger`.
public struct Log: Sendable {
    public static let subsystem = "app.jayansh.UniversityPortal"

    private let logger: Logger

    public init(category: String) {
        logger = Logger(subsystem: Self.subsystem, category: category)
    }

    public func debug(_ message: String) {
        logger.debug("\(Self.render(message), privacy: .public)")
    }

    public func info(_ message: String) {
        logger.info("\(Self.render(message), privacy: .public)")
    }

    public func warning(_ message: String) {
        logger.warning("\(Self.render(message), privacy: .public)")
    }

    public func error(_ message: String) {
        logger.error("\(Self.render(message), privacy: .public)")
    }

    /// The text that is actually written to the log.
    static func render(_ message: String) -> String {
        Redactor.redact(message)
    }
}
