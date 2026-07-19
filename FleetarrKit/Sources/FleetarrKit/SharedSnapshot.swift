import Foundation

/// A small, Codable snapshot of the fleet's status that the app writes and the widget /
/// menu-bar reads via a shared App Group container (spec §9.7). Only non-secret display data.
public struct FleetSnapshot: Codable, Sendable, Equatable {
    public var problemBadgeCount: Int
    public var worstHealthRaw: String
    public var unreachableCount: Int
    public var instances: [InstanceSnapshot]
    public var updatedAt: Date

    public init(
        problemBadgeCount: Int,
        worstHealth: HealthState,
        unreachableCount: Int,
        instances: [InstanceSnapshot],
        updatedAt: Date
    ) {
        self.problemBadgeCount = problemBadgeCount
        self.worstHealthRaw = worstHealth.rawValue
        self.unreachableCount = unreachableCount
        self.instances = instances
        self.updatedAt = updatedAt
    }

    public var worstHealth: HealthState { HealthState(rawValue: worstHealthRaw) ?? .unknown }
}

public struct InstanceSnapshot: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var label: String
    public var serviceTypeRaw: String
    public var healthRaw: String
    public var summaryLine: String?

    public init(
        id: UUID,
        label: String,
        serviceType: ServiceType,
        health: HealthState,
        summaryLine: String?
    ) {
        self.id = id
        self.label = label
        self.serviceTypeRaw = serviceType.rawValue
        self.healthRaw = health.rawValue
        self.summaryLine = summaryLine
    }

    public var serviceType: ServiceType { ServiceType(rawValue: serviceTypeRaw) ?? .sonarr }
    public var health: HealthState { HealthState(rawValue: healthRaw) ?? .unknown }
}

/// Reads/writes the ``FleetSnapshot`` in the shared App Group (spec §9.7).
///
/// Cross-process sharing requires the **App Group** capability (`group.dev.radaiko.Fleetarr`) on
/// both the app and the widget targets. Without it these calls are harmless no-ops.
public enum SharedSnapshotStore {
    public static let appGroupID = "group.dev.radaiko.Fleetarr"
    private static let key = "fleet_snapshot"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroupID) }

    public static func write(_ snapshot: FleetSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults?.set(data, forKey: key)
    }

    public static func read() -> FleetSnapshot? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(FleetSnapshot.self, from: data)
    }
}
