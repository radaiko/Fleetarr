import Foundation

// Decodable shapes for Radarr's secondary detail-screen lists (spec §6.1): the calendar
// (upcoming), recent history, and wanted/missing movies. Kept in a separate file so the core
// status flow in `RadarrModels` is untouched.
//
// As elsewhere in the Radarr models, every field is optional so a partial or older payload still
// decodes (spec: tolerant decoding), and all date-time / .NET date-span fields are decoded as
// `String?` — we never parse them into `Date`, so the decoder's `.iso8601` strategy can never fail
// on a missing or oddly-formatted timestamp. Radarr JSON is camelCase, so no CodingKeys are needed.

/// A `MovieResource` as returned by `GET /api/v3/calendar` and `GET /api/v3/wanted/missing`.
/// Richer than the queue's slimmed ``RadarrMovie``: it carries the three release dates so a
/// calendar / missing row can show *when* a movie is (or was) expected.
struct RadarrListMovie: Decodable {
    let id: Int?
    let title: String?
    let originalTitle: String?
    let year: Int?
    let tmdbId: Int?
    let imdbId: String?
    /// MovieStatusType: "tba" | "announced" | "inCinemas" | "released" | "deleted".
    let status: String?
    let hasFile: Bool?
    let monitored: Bool?
    let isAvailable: Bool?
    let minimumAvailability: String?
    let runtime: Int?
    let certification: String?
    let studio: String?
    /// The three release dates plus a generic `releaseDate` — ISO-8601 date-time strings, decoded
    /// as `String?` (a movie may carry any subset of them).
    let inCinemas: String?
    let digitalRelease: String?
    let physicalRelease: String?
    let releaseDate: String?
}

/// `GET /api/v3/wanted/missing` — paged `MovieResource` wrapper whose records carry release dates
/// (distinct from ``RadarrMissingResponse``, which only surfaces `totalRecords` for the headline).
struct RadarrMissingListResponse: Decodable {
    let page: Int?
    let pageSize: Int?
    let totalRecords: Int?
    let records: [RadarrListMovie]?
}

/// `GET /api/v3/history` — paged wrapper around recent library events (grabs, imports, failures).
struct RadarrHistoryResponse: Decodable {
    let page: Int?
    let pageSize: Int?
    let totalRecords: Int?
    let records: [RadarrHistoryRecord]?
}

struct RadarrHistoryRecord: Decodable {
    let id: Int?
    let movieId: Int?
    /// The release/source title of the grab or import (always present).
    let sourceTitle: String?
    /// MovieHistoryEventType: "grabbed" | "downloadFolderImported" | "movieFolderImported" |
    /// "downloadFailed" | "movieFileDeleted" | "movieFileRenamed" | "downloadIgnored".
    let eventType: String?
    /// ISO-8601 date-time string of when the event happened (decoded as `String?`).
    let date: String?
    let downloadId: String?
    let quality: RadarrQualityWrapper?
    /// Present only when history is fetched with `includeMovie=true`.
    let movie: RadarrListMovie?
    /// Freeform per-event dict; only the few keys Fleetarr surfaces are decoded.
    let data: RadarrHistoryData?
}

/// The `quality` object on a history record: `{ "quality": { "name": … }, "revision": … }`.
struct RadarrQualityWrapper: Decodable {
    let quality: RadarrQualityDetail?
}

struct RadarrQualityDetail: Decodable {
    let name: String?
}

/// Select keys from a history record's freeform `data` dict (keys vary by `eventType`).
struct RadarrHistoryData: Decodable {
    let indexer: String?
    let releaseGroup: String?
    let downloadClient: String?
    let reason: String?
}
