import Foundation

/// The common protocol every one of the seven integrations implements (spec §3.2).
///
/// A new integration can be added by conforming a new client to this protocol without touching
/// unrelated clients. Clients are value types (or actors) carrying an immutable ``ServiceContext``,
/// so they are `Sendable` and safe to run concurrently in a `TaskGroup` (spec §3.2).
public protocol FleetService: Sendable {
    var serviceType: ServiceType { get }

    /// Calls the service's own lightweight status endpoint and reports the actual failure reason
    /// (spec §4). Does not throw — a failure is a `.failure(FleetError)` result.
    func testConnection() async -> ConnectionTestResult

    /// Fetches the dashboard-level status for this instance: health, headline metrics, and
    /// problems (spec §5). Throws a ``FleetError`` on connectivity/decoding failure so the caller
    /// can map it to an unreachable tile without blocking other instances (spec §9.1, §9.2).
    func fetchStatus() async throws(FleetError) -> InstanceStatus

    /// Fetches the detail screen's primary activity list — queue items, sessions, or requests
    /// (spec §6, §8). Default implementation returns an empty list for services without one.
    func fetchActivity() async throws(FleetError) -> [ActivityItem]
}

public extension FleetService {
    func fetchActivity() async throws(FleetError) -> [ActivityItem] { [] }
}
