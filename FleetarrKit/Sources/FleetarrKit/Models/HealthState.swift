import Foundation

/// The app-level status of an instance (spec §2, §5).
///
/// `Comparable` by severity so the fleet-wide worst state is `states.max()`. `unknown` is the
/// lowest (never refreshed / mid first refresh); `unreachable` and `error` are the highest.
public enum HealthState: String, Codable, Sendable, Hashable, CaseIterable, Comparable {
    /// Not yet refreshed, or a refresh is in flight and there is no prior result.
    case unknown
    /// Reachable and reporting no problems.
    case healthy
    /// Reachable and reporting a non-critical problem (a warning-level issue).
    case warning
    /// Reachable but reporting a critical problem (e.g. a Sonarr health error, a failed download).
    case error
    /// Could not be reached — timeout, TLS failure, DNS failure, connection refused, or 401/403.
    /// Distinct from `error` so the user can tell "service is down / I'm off-network" apart from
    /// "service is up but complaining" (spec §4, §6.1).
    case unreachable

    /// Higher = worse. Used to aggregate a fleet-wide headline state.
    public var severityRank: Int {
        switch self {
        case .unknown: return 0
        case .healthy: return 1
        case .warning: return 2
        case .error: return 3
        case .unreachable: return 4
        }
    }

    public static func < (lhs: HealthState, rhs: HealthState) -> Bool {
        lhs.severityRank < rhs.severityRank
    }

    /// Whether this state should draw attention as a "problem" on the dashboard.
    public var isProblem: Bool {
        switch self {
        case .warning, .error, .unreachable: return true
        case .unknown, .healthy: return false
        }
    }
}
