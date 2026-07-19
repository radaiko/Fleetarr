import Foundation

/// A generic in-progress item for a detail screen's primary activity list (spec §6, §8):
/// a download, an import, an active stream, or a pending request.
///
/// Service-specific detail screens may enrich this with typed models, but this common shape lets
/// the shared detail UI render any service's activity list uniformly.
public struct ActivityItem: Sendable, Identifiable, Equatable, Hashable {
    public var id: String
    public var title: String
    public var subtitle: String?
    /// Download/playback progress in `0...1`, or `nil` when not applicable.
    public var progress: Double?
    /// Raw, user-facing status text (e.g. "Downloading", "Importing", "Transcode").
    public var status: String?
    /// Severity if this item represents a problem; `nil` for a healthy in-progress item.
    public var severity: Problem.Severity?
    /// Poster/thumbnail artwork for the row (e.g. a Plex/Jellyfin now-playing image or a Seerr
    /// request poster), already resolved to a fully-authenticated URL; `nil` when unavailable.
    public var artworkURL: URL?
    /// Extra labeled fields for the detail row, in presentation order.
    public var fields: [Field]

    public struct Field: Sendable, Equatable, Hashable, Identifiable {
        public var label: String
        public var value: String
        public var id: String { label }
        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        progress: Double? = nil,
        status: String? = nil,
        severity: Problem.Severity? = nil,
        artworkURL: URL? = nil,
        fields: [Field] = []
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.progress = progress
        self.status = status
        self.severity = severity
        self.artworkURL = artworkURL
        self.fields = fields
    }
}
