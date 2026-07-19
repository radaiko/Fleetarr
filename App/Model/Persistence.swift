import Foundation
import SwiftData
import Security
import os

private let persistenceLog = Logger(subsystem: "dev.radaiko.Fleetarr", category: "Persistence")

/// Builds the SwiftData `ModelContainer`, choosing CloudKit sync vs. local-only at creation time
/// and always degrading to a working local store so the app never dead-launches (spec §3.5).
enum Persistence {
    /// Must match the iCloud container in `App/Fleetarr.entitlements`.
    static let cloudKitContainerID = "iCloud.dev.radaiko.Fleetarr"

    /// - Parameter syncEnabled: the user's persisted preference (read from `UserDefaults`, since we
    ///   must know it *before* opening the store). Sync also requires a usable iCloud account.
    static func makeContainer(syncEnabled: Bool) -> ModelContainer {
        let schema = Schema([InstanceRecord.self])

        // Enable CloudKit when the user opted in AND the app is signed with the CloudKit entitlement.
        // The entitlement check matters because enabling CloudKit *without* it (unsigned/dev builds)
        // makes CloudKit trap on a background thread during mirroring setup — which no `try?` around
        // the init can catch. Do NOT additionally gate on `FileManager.ubiquityIdentityToken`: that
        // token reflects iCloud *Drive/Documents* (ubiquity containers), which this app doesn't use,
        // so it is nil even with a valid iCloud account + CloudKit access — gating on it silently
        // disables sync. If the account is unavailable, CloudKit mirroring just stays idle (no crash).
        let hasCloudKitEntitlement = hasEntitlement("com.apple.developer.icloud-container-identifiers")
        let shouldSync = syncEnabled && hasCloudKitEntitlement
        persistenceLog.notice("makeContainer syncEnabled=\(syncEnabled, privacy: .public) hasCKEntitlement=\(hasCloudKitEntitlement, privacy: .public) shouldSync=\(shouldSync, privacy: .public)")

        let primary = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: shouldSync ? .private(cloudKitContainerID) : .none
        )
        do {
            return try ModelContainer(for: schema, configurations: primary)
        } catch {
            persistenceLog.error("primary (CloudKit) container failed: \(String(describing: error), privacy: .public) — falling back to local")
        }

        // CloudKit unavailable (e.g. missing entitlement in a dev build) → local-only.
        let local = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: .none)
        if let container = try? ModelContainer(for: schema, configurations: local) {
            return container
        }

        // Last resort so the UI still runs.
        let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        // swiftlint:disable:next force_try
        return try! ModelContainer(for: schema, configurations: memory)
    }

    /// Whether the running app was signed with the given entitlement. Used to gate CloudKit so a
    /// dev build without the capability doesn't trap in CloudKit mirroring.
    private static func hasEntitlement(_ key: String) -> Bool {
        #if os(macOS)
        // The unsigned/ad-hoc dev-build crash this guards against is macOS-specific. `SecTask`
        // self-inspection is available there.
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, key as CFString, nil) != nil
        #else
        // On iOS the app always runs with its provisioned entitlements (the SecTask self-inspection
        // APIs aren't available), so assume present and let the iCloud-account check gate sync.
        return true
        #endif
    }
}
