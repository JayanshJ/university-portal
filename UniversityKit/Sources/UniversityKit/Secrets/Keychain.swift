import Foundation
import Security
import Synchronization

/// Every secret the app keeps. Raw values are the Keychain account names.
public enum SecretKind: String, CaseIterable, Sendable {
    case moodleToken = "moodle_token"
    case moodlePrivateToken = "moodle_private_token"
    case cmsUsername = "cms_username"
    case cmsPassword = "cms_password"
    case cmsCookieJar = "cms_cookie_jar"
    /// The ChatGPT sign-in: tokens for the current session.
    case chatgptCredentials = "chatgpt_credentials"
    /// The app's ChatGPT registration (issued client ID, host ID); kept across sign-outs.
    case chatgptRegistration = "chatgpt_registration"
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

/// All secrets in one generic-password item (account "secrets", a JSON object of base64 values),
/// readable only on this Mac and never synced to iCloud. One item means one Keychain approval after
/// an update: the app's certificate has no Team ID, so the Keychain trusts each build by its hash
/// and asks again for every item it reads.
public struct KeychainStore: SecretStore {
    public static let defaultService = "app.jayansh.UniversityPortal"
    static let account = "secrets"

    public let service: String

    /// The decoded item per service, loaded on first use; writes go through to the Keychain.
    private static let vaults = Mutex<[String: [String: Data]]>([:])

    public init(service: String = Self.defaultService) {
        self.service = service
    }

    public func read(_ kind: SecretKind) throws -> Data? {
        try Self.vaults.withLock { vaults in try load(&vaults)[kind.rawValue] }
    }

    public func write(_ data: Data, for kind: SecretKind) throws {
        try Self.vaults.withLock { vaults in
            var secrets = try load(&vaults)
            secrets[kind.rawValue] = data
            try save(secrets)
            vaults[service] = secrets
        }
    }

    public func delete(_ kind: SecretKind) throws {
        try Self.vaults.withLock { vaults in
            var secrets = try load(&vaults)
            guard secrets.removeValue(forKey: kind.rawValue) != nil else { return }
            try save(secrets)
            vaults[service] = secrets
        }
    }

    /// Removes the item and forgets the cache (tests).
    func removeAll() throws {
        try Self.vaults.withLock { vaults in
            vaults[service] = nil
            try deleteItem(Self.account)
        }
    }

    // MARK: - The item

    private func load(_ vaults: inout [String: [String: Data]]) throws -> [String: Data] {
        if let cached = vaults[service] { return cached }
        var secrets = try readItem(Self.account).map { try JSONDecoder().decode([String: Data].self, from: $0) } ?? [:]
        // Before 1.3 every secret had its own item. Move them in; one that can't be read (access
        // denied) stays where it is and is tried again next launch.
        var moved: [String] = []
        for account in legacyAccounts() {
            if secrets[account] == nil {
                guard let data = (try? readItem(account)) ?? nil else { continue }
                secrets[account] = data
            }
            moved.append(account)
        }
        if !moved.isEmpty {
            try save(secrets)
            for account in moved { try? deleteItem(account) }
        }
        vaults[service] = secrets
        return secrets
    }

    private func save(_ secrets: [String: Data]) throws {
        try writeItem(Self.account, data: JSONEncoder().encode(secrets))
    }

    /// Accounts of the old one-item-per-secret layout that still exist (attributes only, so no prompt).
    func legacyAccounts() -> [String] {
        var query = baseQuery(nil)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        let known = Set(SecretKind.allCases.map(\.rawValue))
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.filter(known.contains)
    }

    // MARK: - Keychain items

    func readItem(_ account: String) throws -> Data? {
        var query = baseQuery(account)
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

    func writeItem(_ account: String, data: Data) throws {
        let update = [kSecValueData as String: data] as CFDictionary
        let status = SecItemUpdate(baseQuery(account) as CFDictionary, update)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError(status: status) }

        var item = baseQuery(account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrLabel as String] = account == Self.account ? "University Portal" : "University Portal (\(account))"
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
    }

    func deleteItem(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private func baseQuery(_ account: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false,
        ]
        query[kSecAttrAccount as String] = account
        return query
    }
}
