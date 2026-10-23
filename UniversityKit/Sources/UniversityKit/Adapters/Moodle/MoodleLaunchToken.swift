import CryptoKit
import Foundation

/// The value `launch.php` puts in `moodlemobile://token=<base64>`: `sitehash:::token:::privatetoken`.
public struct MoodleLaunchToken: Sendable, Equatable {
    public var siteHash: String
    public var token: String
    public var privateToken: String?

    public enum ParseError: Error, Equatable {
        case noToken
        case notBase64
        case wrongShape
    }

    /// Accepts the callback URL, a pasted `location:` header line, or the bare base64 value.
    public static func parse(_ input: String) throws -> MoodleLaunchToken {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = value.range(of: "token=") {
            value = String(value[range.upperBound...])
        }
        value = value.removingPercentEncoding ?? value
        value = String(value.prefix { $0.isLetter || $0.isNumber || "+/=-_".contains($0) })
        guard !value.isEmpty else { throw ParseError.noToken }

        // Accept URL-safe base64 and missing padding.
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), let decoded = String(data: data, encoding: .utf8) else {
            throw ParseError.notBase64
        }

        let parts = decoded.components(separatedBy: ":::")
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { throw ParseError.wrongShape }
        return MoodleLaunchToken(
            siteHash: parts[0], token: parts[1],
            privateToken: parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil)
    }

    /// What Moodle should have put in `siteHash`: `md5(wwwroot + passport)` (unconfirmed until the first real reconnect).
    public static func expectedSiteHash(siteURL: URL = MoodleClient.siteURL, passport: String) -> String {
        var wwwroot = siteURL.absoluteString
        while wwwroot.hasSuffix("/") { wwwroot.removeLast() }
        let digest = Insecure.MD5.hash(data: Data((wwwroot + passport).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
