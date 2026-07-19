import Foundation
import Observation
import SwiftData
import FleetarrKit

/// The app's observable state hub: owns the instance list (from SwiftData), runs concurrent
/// refreshes via `FleetRefresher`, and exposes per-instance status + the fleet summary to the UI.
@MainActor
@Observable
final class FleetStore {
    private let context: ModelContext
    private let keychain: KeychainStore
    private let factory: any FleetServiceFactory

    /// Configured instances, sorted by display order (spec §5).
    private(set) var instances: [FleetInstance] = []
    /// Latest refresh result per instance id.
    private(set) var statuses: [UUID: InstanceStatus] = [:]
    /// Instance ids that currently have a secret in the Keychain (computed on `reload`, so the UI
    /// doesn't hit the Keychain on every render).
    private(set) var configuredInstanceIDs: Set<UUID> = []
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?

    init(
        context: ModelContext,
        keychain: KeychainStore = KeychainStore(),
        factory: any FleetServiceFactory = DefaultFleetServiceFactory()
    ) {
        self.context = context
        self.keychain = keychain
        self.factory = factory
        reload()
    }

    // MARK: Derived

    /// Instances shown on the dashboard: enabled and not hidden (spec §5).
    var dashboardInstances: [FleetInstance] {
        instances.filter { $0.isEnabled && !$0.isHiddenFromDashboard }
    }

    /// Combined fleet summary for the header + app badge (spec §5).
    var summary: FleetSummary {
        FleetSummary(statuses: dashboardInstances.compactMap { statuses[$0.id] })
    }

    func status(for instance: FleetInstance) -> InstanceStatus? {
        statuses[instance.id]
    }

    // MARK: Loading

    func reload() {
        let descriptor = FetchDescriptor<InstanceRecord>(
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.label)]
        )
        let records = (try? context.fetch(descriptor)) ?? []
        instances = records.map(\.fleetInstance)
        let keychain = self.keychain
        configuredInstanceIDs = Set(
            instances
                .filter { ((try? keychain.readSecret(for: $0.id)) ?? nil)?.isEmpty == false }
                .map(\.id)
        )
    }

    // MARK: Refresh (concurrent, spec §3.2 / §9.2)

    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        // Capture Sendable values so the credential closure never touches main-actor state.
        let keychain = self.keychain
        let results = await FleetRefresher.refresh(
            instances: dashboardInstances,
            factory: factory,
            credential: { instance in (try? keychain.readSecret(for: instance.id)) ?? nil }
        )
        // Merge so instances not in this pass keep their previous status (spec §9.5).
        for (id, status) in results {
            statuses[id] = status
        }
        lastRefresh = .now
    }

    /// Builds a live service client for an instance if a secret is stored — used by detail screens
    /// to fetch the activity list. Returns `nil` when the instance is unconfigured or its URL is bad.
    func service(for instance: FleetInstance) -> (any FleetService)? {
        guard let secret = (try? keychain.readSecret(for: instance.id)) ?? nil, !secret.isEmpty else {
            return nil
        }
        return try? factory.makeService(for: instance, credential: secret)
    }

    // MARK: Test connection (spec §4)

    func testConnection(_ instance: FleetInstance, secret: String) async -> ConnectionTestResult {
        do {
            let service = try factory.makeService(for: instance, credential: secret)
            return await service.testConnection()
        } catch {
            return .failure(error)
        }
    }

    // MARK: CRUD

    /// Inserts or updates an instance (upsert by `id`) and stores its secret in the Keychain.
    /// Passing `secret == nil` leaves any existing stored secret untouched.
    func save(_ instance: FleetInstance, secret: String?) {
        let id = instance.id
        let descriptor = FetchDescriptor<InstanceRecord>(predicate: #Predicate { $0.id == id })
        if let existing = try? context.fetch(descriptor).first {
            existing.apply(instance)
            existing.updatedAt = .now
        } else {
            var toInsert = instance
            if toInsert.sortOrder == 0 {
                toInsert.sortOrder = (instances.map(\.sortOrder).max() ?? 0) + 1
            }
            context.insert(InstanceRecord.from(toInsert))
        }
        try? context.save()

        if let secret, !secret.isEmpty {
            try? keychain.save(secret, for: id)
        }
        reload()
    }

    func delete(_ instance: FleetInstance) {
        let id = instance.id
        let descriptor = FetchDescriptor<InstanceRecord>(predicate: #Predicate { $0.id == id })
        if let existing = try? context.fetch(descriptor).first {
            context.delete(existing)
        }
        try? context.save()
        try? keychain.delete(for: id)
        statuses[id] = nil
        reload()
    }

    /// Whether a secret is stored for this instance (drives the "not configured" tile state).
    /// Uses the cached set computed on `reload`, so this never hits the Keychain during rendering.
    func hasStoredSecret(for instance: FleetInstance) -> Bool {
        configuredInstanceIDs.contains(instance.id)
    }
}
