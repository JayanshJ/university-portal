import Foundation
import Security

/// Every secret the app keeps. Raw values are the Keychain account names.
public enum SecretKind: String, CaseIterable, Sendable {
    case moodleToken = "moodle_token"
    case moodlePrivateToken = "moodle_private_token"
    case cmsUsername = "cms_username"
    case cmsPassword = "cms_password"
    case cmsCookieJar = "cms_cookie_jar"
}

public protocol SecretStore: Sendable {
    func read(_ kind: SecretKind) throws -> Data?
    func write(_ data: Data, for kind: SecretKind) throws
    func delete(_ kind: SecretKind) throws
}

extension SecretStore {
    public func readString(_ kind: SecretKind) throws -> String? {
        try read(kind).map { String(decoding: $0, as: UTF8.self) }
    }

    public func writeString(_ value: String, for kind: SecretKind) throws {
        try write(Data(value.utf8), for: kind)
    }
}

public struct KeychainError: Error, CustomStringConvertible {
    public let status: OSStatus

    public var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
        return "Keychain error \(status): \(message)"
    }
}

/// Generic-password items, readable only on this Mac and never synced to iCloud.
public struct KeychainStore: SecretStore {
    public static let defaultService = "app.jayansh.UniversityPortal"

    public let service: String

    public init(service: String = Self.defaultService) {
        self.service = service
    }

    public func read(_ kind: SecretKind) throws -> Data? {
        var query = baseQuery(kind)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainError(status: status)
        }
    }

    public func write(_ data: Data, for kind: SecretKind) throws {
        let update = [kSecValueData as String: data] as CFDictionary
        let status = SecItemUpdate(baseQuery(kind) as CFDictionary, update)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError(status: status) }

        var item = baseQuery(kind)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrLabel as String] = "University Portal (\(kind.rawValue))"
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
    }

    public func delete(_ kind: SecretKind) throws {
        let status = SecItemDelete(baseQuery(kind) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private func baseQuery(_ kind: SecretKind) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: kind.rawValue,
            kSecAttrSynchronizable as String: false,
        ]
    }
}
