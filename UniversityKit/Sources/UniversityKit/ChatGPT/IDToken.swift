import Foundation
import Security

/// The claims the app relies on from a verified ChatGPT ID token.
public struct IDTokenClaims: Sendable, Equatable {
    public var subject: String
    public var email: String?
    public var expiresAt: Date
}

public enum IDTokenError: Error, Equatable {
    case malformed
    case unsupportedAlgorithm(String)
    case unknownKey
    case badSignature
    case wrongIssuer
    case wrongAudience
    case expired
    case wrongNonce
}

/// Verifies an RS256 ID token: signature against the issuer's JWKS, then `iss`, `aud`, `exp` and `nonce`.
struct IDTokenVerifier: Sendable {
    let issuer: String
    /// The PKCS#1 DER public key for a key ID (from the JWKS), or nil when unknown.
    let key: @Sendable (String) async throws -> Data?

    func verify(_ token: String, clientId: String, nonce: String?, now: Date = .now, checkExpiry: Bool = true) async throws -> IDTokenClaims {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let headerData = Base64URL.decode(parts[0]), let payloadData = Base64URL.decode(parts[1]),
              let signature = Base64URL.decode(parts[2]),
              let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let claims = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            throw IDTokenError.malformed
        }
        let algorithm = header["alg"] as? String ?? ""
        guard algorithm == "RS256" else { throw IDTokenError.unsupportedAlgorithm(algorithm) }
        guard let kid = header["kid"] as? String, let der = try await key(kid),
              let publicKey = RSAPublicKey.make(der: der) else { throw IDTokenError.unknownKey }

        let signedPart = Data((parts[0] + "." + parts[1]).utf8)
        guard SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, signedPart as CFData,
                                    signature as CFData, nil) else {
            throw IDTokenError.badSignature
        }

        let iss = (claims["iss"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard iss == issuer.trimmingCharacters(in: CharacterSet(charactersIn: "/")) else { throw IDTokenError.wrongIssuer }
        let audiences = (claims["aud"] as? [String]) ?? [(claims["aud"] as? String) ?? ""]
        guard audiences.contains(clientId) else { throw IDTokenError.wrongAudience }
        let exp = Date(timeIntervalSince1970: (claims["exp"] as? Double) ?? 0)
        if checkExpiry, exp.addingTimeInterval(60) < now { throw IDTokenError.expired }
        if let nonce, claims["nonce"] as? String != nonce { throw IDTokenError.wrongNonce }
        guard let subject = claims["sub"] as? String else { throw IDTokenError.malformed }
        return IDTokenClaims(subject: subject, email: claims["email"] as? String, expiresAt: exp)
    }
}

enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}

/// An RSA public key from a JWK's modulus and exponent, as a PKCS#1 `RSAPublicKey` DER sequence.
enum RSAPublicKey {
    static func der(modulus: Data, exponent: Data) -> Data {
        sequence(integer(modulus) + integer(exponent))
    }

    static func make(der: Data) -> SecKey? {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]
        return SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil)
    }

    static func integer(_ bytes: Data) -> Data {
        var value = Data(bytes.drop { $0 == 0 })
        if value.isEmpty { value = Data([0]) }
        if value.first! & 0x80 != 0 { value.insert(0, at: 0) }  // keep it positive
        return Data([0x02]) + length(value.count) + value
    }

    static func sequence(_ content: Data) -> Data {
        Data([0x30]) + length(content.count) + content
    }

    static func length(_ count: Int) -> Data {
        if count < 0x80 { return Data([UInt8(count)]) }
        var bytes: [UInt8] = []
        var value = count
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
}
