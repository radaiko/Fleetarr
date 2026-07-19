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
        service: String = "dev.radaiko.Fleetarr.credentials",
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

    /// Whether a secret exists for this instance, WITHOUT decrypting it. An attributes-only query
    /// doesn't touch the confidential data, so it never triggers the macOS keychain-access prompt —
    /// unlike ``readSecret(for:)``. Use this for UI "configured?" checks.
    public func exists(for id: UUID) -> Bool {
        exists(account: id.uuidString)
    }

    public func exists(account: String) -> Bool {
        exists(account: account, synchronizable: nil)
    }

    /// Whether an item exists for this account in a specific iCloud-sync state (`nil` = either).
    /// Attributes-only, so it never triggers the keychain-access prompt.
    public func exists(account: String, synchronizable: Bool?) -> Bool {
        var query = baseQuery(account: account, synchronizable: synchronizable)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = kCFBooleanTrue // attributes only — no data, no prompt
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    /// Re-homes an instance's secret to the desired iCloud-Keychain sync state (spec §3.3): when a
    /// variant in the opposite state exists, it reads the secret, removes every stored variant, and
    /// re-saves it in the desired state. A no-op when nothing is stored or it's already in the
    /// desired state, so it's safe to run on every launch — this is what makes turning iCloud sync
    /// off actually stop API keys from travelling via iCloud Keychain (not just future saves).
    public func setSynchronizable(_ desired: Bool, for id: UUID) {
        let account = id.uuidString
        guard exists(account: account, synchronizable: !desired) else { return }
        guard let secret = (try? readSecret(account: account)) ?? nil,
              let data = secret.data(using: .utf8) else { return }
        try? delete(account: account)
        try? write(data, account: account, synchronizable: desired)
    }

    // MARK: Account-keyed operations

    public func save(_ secret: String, account: String) throws {
        guard let data = secret.data(using: .utf8) else { throw KeychainError.encodingFailed }

        do {
            try write(data, account: account, synchronizable: synchronizable)
        } catch {
            // A synchronizable (iCloud Keychain) item requires the iCloud/Keychain-Sharing
            // entitlement, which unsigned / development builds don't have. Fall back to a local,
            // non-synced item so the app still works. Signed builds succeed on the first attempt
            // and get real iCloud Keychain sync.
            if synchronizable {
                try write(data, account: account, synchronizable: false)
            } else {
                throw error
            }
        }
    }

    private func write(_ data: Data, account: String, synchronizable: Bool) throws {
        var query = baseQuery(account: account, synchronizable: synchronizable)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        query[kSecValueData as String] = data
        // A syncable accessibility class (not a ...ThisDeviceOnly one) for iCloud Keychain.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
    }

    public func readSecret(account: String) throws -> String? {
        // Match both synced and local items so a dev-build fallback item is still found.
        var query = baseQuery(account: account, synchronizable: nil)
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
        let status = SecItemDelete(baseQuery(account: account, synchronizable: nil) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: Query building

    /// - Parameter synchronizable: `true`/`false` to target that sync state, or `nil` to match any
    ///   (used for reads/deletes so both synced and local items are found).
    private func baseQuery(account: String, synchronizable: Bool?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let synchronizable {
            query[kSecAttrSynchronizable as String] = synchronizable ? kCFBooleanTrue as Any : kCFBooleanFalse as Any
        } else {
            query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        }
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}
