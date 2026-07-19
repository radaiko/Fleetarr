import Foundation

// Decodable shapes for the Sonarr v3 history endpoint (`GET /api/v3/history`), used by the
// detail-screen "Recent history" list (spec §6.1). Kept in a dedicated file so the primary
// `SonarrModels.swift` stays focused on the dashboard-status wire models.
//
// As with the rest of the Sonarr models, every field is optional: real servers omit fields
// depending on version and the include* flags, so tolerant decoding keeps the list alive rather
// than failing the whole fetch.

/// The `HistoryResource` `PagingResource` envelope returned by `GET /api/v3/history`.
struct SonarrHistoryPaging: Decodable {
    let page: Int?
    let pageSize: Int?
    let totalRecords: Int?
    let records: [SonarrHistoryRecord]?
}

/// One `HistoryResource`: a grab / import / failure event for an episode.
struct SonarrHistoryRecord: Decodable {
    let id: Int?
    let episodeId: Int?
    let seriesId: Int?
    let sourceTitle: String?
    /// ISO-8601 date-time the event occurred.
    let date: String?
    let downloadId: String?
    /// EpisodeHistoryEventType: `grabbed` | `downloadFolderImported` | `seriesFolderImported` |
    /// `downloadFailed` | `importFailed` | `episodeFileDeleted` | `episodeFileRenamed` |
    /// `downloadIgnored` | `unknown`.
    let eventType: String?
    let quality: SonarrQualityModel?
    /// Free-form string→string extras (indexer, releaseGroup, downloadClient, …). Documented as a
    /// `Dictionary<string,string>` by the API, so decoding it as `[String: String]?` is safe.
    let data: [String: String]?

    /// A stable identifier for the activity row, tolerant of a missing `id`.
    var identifier: String {
        if let id { return String(id) }
        if let downloadId, !downloadId.isEmpty { return downloadId }
        return sourceTitle ?? "unknown"
    }
}

/// Minimal decode of Sonarr's `QualityModel` — only the nested human quality name is surfaced.
struct SonarrQualityModel: Decodable {
    let quality: Quality?

    struct Quality: Decodable {
        let id: Int?
        let name: String?
    }

    var name: String? { quality?.name }
}
