import Foundation

/// A fleet-wide aggregate for the dashboard's combined summary row and app-icon badge (spec §5).
public struct FleetSummary: Sendable, Equatable {
    /// Total problems counting toward the badge (cosmetic excluded, spec §6.4), across the fleet.
    public var problemBadgeCount: Int
    /// The worst health state across all refreshed instances.
    public var worstHealth: HealthState
    /// How many instances are currently unreachable.
    public var unreachableCount: Int

    public init(problemBadgeCount: Int = 0, worstHealth: HealthState = .unknown, unreachableCount: Int = 0) {
        self.problemBadgeCount = problemBadgeCount
        self.worstHealth = worstHealth
        self.unreachableCount = unreachableCount
    }

    public init(statuses: some Collection<InstanceStatus>) {
        self.problemBadgeCount = statuses.reduce(0) { $0 + $1.badgeCount }
        self.worstHealth = statuses.map(\.health).max() ?? .unknown
        self.unreachableCount = statuses.filter { $0.health == .unreachable }.count
    }
}

/// Runs per-instance refreshes concurrently so one slow or unreachable instance never delays the
/// others (spec §3.2, §9.1). Each instance's failure is isolated to its own tile (spec §9.2).
public enum FleetRefresher {
    /// Refreshes an already-built set of services concurrently, keyed by instance id.
    public static func refresh(
        services: [(id: UUID, service: any FleetService)]
    ) async -> [UUID: InstanceStatus] {
        await withTaskGroup(of: (UUID, InstanceStatus).self) { group in
            for item in services {
                group.addTask {
                    do {
                        return (item.id, try await item.service.fetchStatus())
                    } catch let error as FleetError {
                        return (item.id, .unreachable(error))
                    } catch {
                        return (item.id, .unreachable(.transport("unexpected failure")))
                    }
                }
            }
            var results: [UUID: InstanceStatus] = [:]
            for await (id, status) in group {
                results[id] = status
            }
            return results
        }
    }

    /// Convenience: builds services for the enabled instances via `factory` (pulling each secret
    /// from `credential`) and refreshes them concurrently.
    ///
    /// - An enabled instance with no stored credential yields an `.unknown`/unconfigured status.
    /// - A factory failure (bad URL, unimplemented service) yields an error/unreachable status.
    public static func refresh(
        instances: [FleetInstance],
        factory: any FleetServiceFactory,
        credential: @Sendable (FleetInstance) -> String?
    ) async -> [UUID: InstanceStatus] {
        var services: [(id: UUID, service: any FleetService)] = []
        var preflight: [UUID: InstanceStatus] = [:]

        for instance in instances where instance.isEnabled {
            guard let secret = credential(instance), !secret.isEmpty else {
                preflight[instance.id] = InstanceStatus(
                    health: .unknown,
                    problems: [Problem(severity: .warning, title: "Not configured",
                                       detail: "No credential is stored for this instance.",
                                       source: "connection")]
                )
                continue
            }
            do {
                let service = try factory.makeService(for: instance, credential: secret)
                services.append((instance.id, service))
            } catch {
                preflight[instance.id] = .unreachable(error)
            }
        }

        var results = await refresh(services: services)
        results.merge(preflight) { current, _ in current }
        return results
    }
}
