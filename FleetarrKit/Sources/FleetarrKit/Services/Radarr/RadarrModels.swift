import Foundation

// Decodable shapes for the Radarr v3 REST API (base path /api/v3). Structurally near-identical to
// Sonarr v3 but movie-oriented (MovieResource / movieId instead of Series/EpisodeResource).
//
// All Radarr JSON is camelCase, so no CodingKeys are needed — property names match the wire format.
// Date-time and .NET date-span fields (e.g. `timeleft` = "HH:MM:SS") are decoded as `String?` to
// stay tolerant: real servers omit fields, and we never need to parse them into `Date` here.
// Every field is optional so a partial/older payload still decodes (spec: tolerant decoding).

/// GET /api/v3/system/status — the cheap authenticated call used for testConnection.
struct RadarrSystemStatus: Decodable {
    let appName: String?
    let instanceName: String?
    let version: String?
    let branch: String?
    let packageVersion: String?
    let osName: String?
    let runtimeVersion: String?
    let isDocker: Bool?
    let authentication: String?
    let buildTime: String?
    let startTime: String?
}

/// GET /api/v3/health — array of health checks. Empty array means fully healthy; only
/// notice/warning/error rows are typically returned.
struct RadarrHealthResource: Decodable {
    let id: Int?
    let source: String?
    /// HealthCheckResult: "ok" | "notice" | "warning" | "error".
    let type: String?
    let message: String?
    let wikiUrl: String?
}

/// GET /api/v3/queue — a paged wrapper around the live download queue.
struct RadarrQueueResponse: Decodable {
    let page: Int?
    let pageSize: Int?
    let sortKey: String?
    let sortDirection: String?
    let totalRecords: Int?
    let records: [RadarrQueueRecord]?
}

struct RadarrQueueRecord: Decodable {
    /// Queue-item id (used for DELETE /queue/{id}).
    let id: Int?
    let movieId: Int?
    /// Present only when the queue is fetched with includeMovie=true.
    let movie: RadarrMovie?
    /// The release title (always present, even without includeMovie).
    let title: String?
    /// QueueStatus: "queued" | "paused" | "downloading" | "completed" | "failed" | "warning" | …
    let status: String?
    /// "ok" | "warning" | "error" — the primary signal for a queue problem.
    let trackedDownloadStatus: String?
    /// "downloading" | "importBlocked" | "importPending" | "importing" | "failed" | …
    let trackedDownloadState: String?
    let errorMessage: String?
    let statusMessages: [RadarrStatusMessage]?
    let size: Double?
    let sizeleft: Double?
    /// .NET date-span string, e.g. "00:12:44" or "1.03:00:00".
    let timeleft: String?
    let estimatedCompletionTime: String?
    let downloadClient: String?
    let indexer: String?
}

struct RadarrStatusMessage: Decodable {
    let title: String?
    let messages: [String]?
}

/// A slimmed MovieResource — only the fields Fleetarr surfaces on a tile/detail row.
struct RadarrMovie: Decodable {
    let id: Int?
    let title: String?
    let year: Int?
    let tmdbId: Int?
    let imdbId: String?
    let hasFile: Bool?
    let monitored: Bool?
    let isAvailable: Bool?
    let runtime: Int?
}

/// GET /api/v3/wanted/missing — paged; only `totalRecords` is needed for the headline count.
struct RadarrMissingResponse: Decodable {
    let page: Int?
    let pageSize: Int?
    let totalRecords: Int?
    let records: [RadarrMovie]?
}
