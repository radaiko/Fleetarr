import Foundation

/// A single labeled headline statistic shown on a dashboard tile (spec §5).
///
/// The dashboard renders each instance's ``InstanceStatus/headline`` as a row of chips, so every
/// service type maps its own metrics onto the same neutral presentation:
/// - Sonarr/Radarr: `missing`, `queue` (+ error emphasis if the queue has a problem)
/// - Prowlarr: `failing indexers`
/// - Seerr: `pending`
/// - SABnzbd: `speed`, `queue`, plus a paused/failed flag
/// - Plex/Jellyfin: `streams`
public struct MetricChip: Sendable, Equatable, Identifiable, Hashable {
    /// Visual emphasis, paired with an icon/text so it never relies on color alone (spec §9.6).
    public enum Emphasis: Int, Sendable, Hashable {
        case normal
        case warning
        case error
    }

    public var label: String
    public var value: String
    public var systemImageName: String?
    public var emphasis: Emphasis

    public var id: String { label }

    public init(
        label: String,
        value: String,
        systemImageName: String? = nil,
        emphasis: Emphasis = .normal
    ) {
        self.label = label
        self.value = value
        self.systemImageName = systemImageName
        self.emphasis = emphasis
    }
}
