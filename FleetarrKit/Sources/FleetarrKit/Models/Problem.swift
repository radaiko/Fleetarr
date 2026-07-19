import Foundation

/// Something surfaced to the user as needing attention (spec §2): a service-reported health
/// issue, a Fleetarr-detected connectivity failure, or a queue/download entry in a bad state.
public struct Problem: Sendable, Identifiable, Equatable, Hashable, Codable {
    /// User-facing severity. `cosmetic` problems are shown in detail views but **must not** count
    /// toward the fleet problem badge (spec §6.4).
    public enum Severity: Int, Sendable, Hashable, Comparable, CaseIterable, Codable {
        case cosmetic
        case warning
        case error

        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public var id: String
    public var severity: Severity
    public var title: String
    public var detail: String?
    /// Where the problem came from, e.g. "health", "queue", "indexer", "connection".
    public var source: String?

    public init(
        id: String = UUID().uuidString,
        severity: Severity,
        title: String,
        detail: String? = nil,
        source: String? = nil
    ) {
        self.id = id
        self.severity = severity
        self.title = title
        self.detail = detail
        self.source = source
    }

    /// Cosmetic problems are deliberately excluded from the fleet problem count (spec §6.4).
    public var countsTowardBadge: Bool {
        severity != .cosmetic
    }
}

public extension Sequence where Element == Problem {
    /// The number of problems that should count toward the fleet-wide badge (spec §5, §6.4).
    var badgeCount: Int {
        reduce(0) { $0 + ($1.countsTowardBadge ? 1 : 0) }
    }

    /// The worst severity present, ignoring cosmetic-only sets for problem determination.
    var worstBadgeSeverity: Problem.Severity? {
        filter(\.countsTowardBadge).map(\.severity).max()
    }
}
