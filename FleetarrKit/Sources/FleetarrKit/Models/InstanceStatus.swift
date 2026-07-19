import Foundation

/// The result of a dashboard-level refresh for one instance (spec §5).
///
/// This is what a tile renders: a health state, a row of headline metric chips, and the list of
/// problems the refresh surfaced. Detailed activity (queue items, sessions, requests) is fetched
/// separately by the detail screen; see ``FleetService/fetchActivity()``.
public struct InstanceStatus: Sendable, Equatable {
    public var health: HealthState
    /// Headline metric chips for the tile, in display order (spec §5).
    public var headline: [MetricChip]
    /// Problems surfaced by this refresh (health issues, failed queue items, connectivity).
    public var problems: [Problem]
    /// Optional short one-liner shown under the metrics (e.g. "Downloading at 12 MB/s").
    public var summaryLine: String?
    /// Service version string when known (from the status/system endpoint), for display.
    public var serviceVersion: String?

    public init(
        health: HealthState,
        headline: [MetricChip] = [],
        problems: [Problem] = [],
        summaryLine: String? = nil,
        serviceVersion: String? = nil
    ) {
        self.health = health
        self.headline = headline
        self.problems = problems
        self.summaryLine = summaryLine
        self.serviceVersion = serviceVersion
    }

    /// Number of problems that count toward the fleet badge (excludes cosmetic; spec §6.4).
    public var badgeCount: Int { problems.badgeCount }

    /// A convenience unreachable status carrying the connectivity error (spec §9.2, §9.5).
    public static func unreachable(_ error: FleetError) -> InstanceStatus {
        InstanceStatus(
            health: .unreachable,
            problems: [
                Problem(
                    severity: .error,
                    title: "Unreachable",
                    detail: error.userMessage,
                    source: "connection"
                )
            ],
            summaryLine: error.userMessage
        )
    }
}
