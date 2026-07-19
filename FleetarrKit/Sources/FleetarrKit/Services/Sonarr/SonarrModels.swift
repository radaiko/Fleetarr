import Foundation

// Decodable shapes for the Sonarr v3 REST API (base path /api/v3).
//
// Sonarr uses camelCase field names that already match these property names, so no CodingKeys are
// needed. Every field is optional: real servers omit fields depending on version and the include*
// query flags, so tolerant decoding keeps a tile alive rather than failing the whole refresh.

/// `GET /api/v3/system/status` — the connectivity + auth probe. Only `version` is used here.
struct SonarrSystemStatus: Decodable {
    let version: String?
    let appName: String?
    let instanceName: String?
    let branch: String?
}

/// One entry from `GET /api/v3/health` (a bare array).
///
/// `wikiUrl` is documented in the OpenAPI spec as an object, but the real runtime JSON serializes
/// it as a plain string URL (Sonarr issue #7788) — so it is decoded as `String?`.
struct SonarrHealth: Decodable {
    let source: String?
    /// HealthCheckResult: `ok` | `notice` | `warning` | `error`.
    let type: String?
    let message: String?
    let wikiUrl: String?
}

/// The `PagingResource` envelope returned by paged endpoints (queue, wanted/missing, history).
struct SonarrQueue: Decodable {
    let page: Int?
    let pageSize: Int?
    let totalRecords: Int?
    let records: [SonarrQueueRecord]?
}

struct SonarrQueueRecord: Decodable {
    let id: Int?
    let title: String?
    /// QueueStatus: `queued` | `paused` | `downloading` | `completed` | `failed` | `warning` | …
    let status: String?
    /// TrackedDownloadStatus: `ok` | `warning` | `error` — drives the row severity.
    let trackedDownloadStatus: String?
    /// TrackedDownloadState: `downloading` | `importPending` | `importing` | `failed` | …
    let trackedDownloadState: String?
    let errorMessage: String?
    let statusMessages: [SonarrStatusMessage]?
    /// Total size in bytes (JSON number / double).
    let size: Double?
    /// Remaining bytes — note the lowercase `l` in the wire field name.
    let sizeleft: Double?
    /// A .NET TimeSpan string like "00:12:34" or "1.05:11:20" — not a date. Absent when idle.
    let timeleft: String?
    let downloadClient: String?
    let downloadId: String?
    let indexer: String?
    let protocolName: String?

    enum CodingKeys: String, CodingKey {
        case id, title, status, trackedDownloadStatus, trackedDownloadState
        case errorMessage, statusMessages, size, sizeleft, timeleft
        case downloadClient, downloadId, indexer
        case protocolName = "protocol"
    }

    /// A stable identifier for problem/activity rows, tolerant of a missing `id`.
    var identifier: String {
        if let id { return String(id) }
        if let downloadId, !downloadId.isEmpty { return downloadId }
        return title ?? "unknown"
    }
}

struct SonarrStatusMessage: Decodable {
    let title: String?
    let messages: [String]?
}

/// `GET /api/v3/wanted/missing` — an `EpisodeResource` `PagingResource`. Only `totalRecords` is
/// needed for the "Missing" headline count, but `records` are decoded for completeness.
struct SonarrEpisodePaging: Decodable {
    let page: Int?
    let pageSize: Int?
    let totalRecords: Int?
    let records: [SonarrEpisode]?
}

/// An `EpisodeResource`, as returned bare by `GET /api/v3/calendar` and inside missing paging.
struct SonarrEpisode: Decodable {
    let id: Int?
    let seriesId: Int?
    let seasonNumber: Int?
    let episodeNumber: Int?
    let title: String?
    let airDate: String?
    let airDateUtc: String?
    let hasFile: Bool?
    let monitored: Bool?
    let series: SonarrSeries?
}

struct SonarrSeries: Decodable {
    let id: Int?
    let title: String?
    let titleSlug: String?
    let status: String?
}
