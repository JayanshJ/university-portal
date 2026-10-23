import Foundation

/// Strips secrets from text before it is logged.
public enum Redactor {
    public static let placeholder = "[REDACTED]"

    // Each pattern keeps group 1 (the key) and replaces the value after it.
    private static let patterns: [NSRegularExpression] = [
        // wstoken=…, token=…, privatetoken=…, moodlemobile://token=…
        #"(?i)(token=)[^&\s"'<>]+"#,
        // data[User][password]=… in a form body, plain or percent-encoded
        #"(?i)(data(?:\[|%5B)User(?:\]|%5D)(?:\[|%5B)password(?:\]|%5D)=)[^&\s"'<>]+"#,
        // "password": "…" in JSON
        #"(?i)("password"\s*:\s*")[^"]*"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    public static func redact(_ text: String) -> String {
        patterns.reduce(text) { text, pattern in
            pattern.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text),
                withTemplate: "$1\(placeholder)")
        }
    }
}
