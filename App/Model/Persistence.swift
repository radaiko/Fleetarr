import Foundation
import SwiftData
import Security

/// Builds the SwiftData `ModelContainer`, choosing CloudKit sync vs. local-only at creation time
/// and always degrading to a working local store so the app never dead-launches (spec §3.5).
enum Persistence {
    /// Must match the iCloud container in `App/Fleetarr.entitlements`.
    static let cloudKitContainerID = "iCloud.net.radaiko.Fleetarr"

    /// - Parameter syncEnabled: the user's persisted preference (read from `UserDefaults`, since we
    ///   must know it *before* opening the store). Sync also requires a usable iCloud account.
    static func makeContainer(syncEnabled: Bool) -> ModelContainer {
        let schema = Schema([InstanceRecord.self])

        // Only sync when: the user opted in, an iCloud account is available, AND the app actually
        // carries the CloudKit entitlement. The last check matters because enabling CloudKit
        // without the entitlement (unsigned / dev builds) makes CloudKit *trap on a background
        // thread* during mirroring setup — which no `try?` around the init can catch. Deciding the
        // config at creation time (never mutating a live container) also avoids the
        // loadIssueModelContainer crash from flipping .none -> .private on an existing store.
        let hasICloud = FileManager.default.ubiquityIdentityToken != nil
        let hasCloudKitEntitlement = hasEntitlement("com.apple.developer.icloud-container-identifiers")
        let shouldSync = syncEnabled && hasICloud && hasCloudKitEntitlement

        let primary = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: shouldSync ? .private(cloudKitContainerID) : .none
        )
        if let container = try? ModelContainer(for: schema, configurations: primary) {
            return container
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
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, key as CFString, nil) != nil
    }
}
