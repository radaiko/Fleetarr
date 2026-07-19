import Foundation
import Security

/// Stores per-instance secrets (API keys, tokens, passwords) in the Keychain, synchronized to the
/// user's iCloud Keychain by default (spec §3.3, §3.5).
///
/// iCloud Keychain items are end-to-end encrypted to the user's trusted-device circle, so this
/// satisfies the Keychain-only rule while staying consistent across devices. Secrets are keyed by
/// the instance's `UUID` and are **never** written to UserDefaults, the SwiftData store, or logs.
public struct KeychainStore: Sendable {
    public enum KeychainError: Error, Sendable, Equatable {
        case encodingFailed
        case unexpectedStatus(OSStatus)
    }

    /// The keychain "service" attribute grouping all Fleetarr credentials.
    public let service: String
    /// When true, items are marked synchronizable so they travel via iCloud Keychain (spec §3.5).
    public let synchronizable: Bool
    /// Optional keychain access group (set when the app uses Keychain Sharing entitlement).
    public let accessGroup: String?

    public init(
        service: String = "net.radaiko.Fleetarr.credentials",
        synchronizable: Bool = true,
        accessGroup: String? = nil
    ) {
        self.service = service
        self.synchronizable = synchronizable
        self.accessGroup = accessGroup
    }

    // MARK: UUID-keyed convenience

    public func save(_ secret: String, for id: UUID) throws {
        try save(secret, account: id.uuidString)
    }

    public func readSecret(for id: UUID) throws -> String? {
        try readSecret(account: id.uuidString)
    }

    public func delete(for id: UUID) throws {
        try delete(account: id.uuidString)
    }

    // MARK: Account-keyed operations

    public func save(_ secret: String, account: String) throws {
        guard let data = secret.data(using: .utf8) else { throw KeychainError.encodingFailed }

        // Try to update an existing item first, then add if missing.
        let updateStatus = SecItemUpdate(
            baseQuery(account: account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        var addQuery = baseQuery(account: account)
        addQuery[kSecValueData as String] = data
        // Must be a syncable accessibility class for iCloud Keychain (not a ...ThisDeviceOnly one).
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
    }

    public func readSecret(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: Query building

    private func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable ? kCFBooleanTrue as Any : kCFBooleanFalse as Any,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}
