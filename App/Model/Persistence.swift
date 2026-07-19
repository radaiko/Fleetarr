import Foundation
import SwiftData

/// Builds the SwiftData `ModelContainer`, choosing CloudKit sync vs. local-only at creation time
/// and always degrading to a working local store so the app never dead-launches (spec §3.5).
enum Persistence {
    /// Must match the iCloud container in `App/Fleetarr.entitlements`.
    static let cloudKitContainerID = "iCloud.net.radaiko.Fleetarr"

    /// - Parameter syncEnabled: the user's persisted preference (read from `UserDefaults`, since we
    ///   must know it *before* opening the store). Sync also requires a usable iCloud account.
    static func makeContainer(syncEnabled: Bool) -> ModelContainer {
        let schema = Schema([InstanceRecord.self])

        // Only sync when the user opted in AND an iCloud account is actually available. Deciding
        // the CloudKit config at creation time (never mutating a live container) avoids the
        // loadIssueModelContainer crash from flipping .none -> .private on an existing store.
        let hasICloud = FileManager.default.ubiquityIdentityToken != nil
        let shouldSync = syncEnabled && hasICloud

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
}
