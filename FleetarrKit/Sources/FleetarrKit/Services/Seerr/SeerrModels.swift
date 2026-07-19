import Foundation

// Decodable shapes for the Seerr (Overseerr/Jellyseerr) REST API rooted at `/api/v1`.
//
// Decoding is deliberately tolerant: real servers (and different Overseerr/Jellyseerr versions)
// omit fields the spec documents, so nearly everything is optional. Field names already match the
// wire format (camelCase), so no CodingKeys are needed.

/// `GET /api/v1/status` — unauthenticated reachability + version probe.
struct SeerrStatus: Decodable {
    let version: String?
    let commitTag: String?
    let updateAvailable: Bool?
    let commitsBehind: Int?
    let restartRequired: Bool?
}

/// `GET /api/v1/request/count` — aggregate request counts by state.
///
/// NOTE: these keys differ from the list-endpoint `filter` enum (no `unavailable`/`deleted`).
struct SeerrRequestCount: Decodable {
    let total: Int?
    let movie: Int?
    let tv: Int?
    let pending: Int?
    let approved: Int?
    let declined: Int?
    let processing: Int?
    let available: Int?
    let completed: Int?
}

/// `GET /api/v1/request` — a paginated page of `MediaRequest`s.
struct SeerrRequestPage: Decodable {
    let pageInfo: SeerrPageInfo?
    let results: [SeerrRequest]?
}

struct SeerrPageInfo: Decodable {
    let page: Int?
    let pages: Int?
    let pageSize: Int?
    let results: Int?
}

/// A single `MediaRequest`. `type` and `media.mediaType` both carry `"movie"`/`"tv"` at runtime
/// even though the OpenAPI schema omits `type`.
struct SeerrRequest: Decodable {
    let id: Int
    /// `RequestStatus`: 1=PENDING, 2=APPROVED, 3=DECLINED, 4=FAILED, 5=COMPLETED.
    let status: Int?
    let type: String?
    let is4k: Bool?
    let media: SeerrMedia?
    let requestedBy: SeerrUser?
    let createdAt: String?
    let updatedAt: String?
}

/// The media the request targets. Resolving a human title/poster needs a TMDB lookup, which is
/// out of scope for this integration — only the identifiers are decoded here.
struct SeerrMedia: Decodable {
    let id: Int?
    let tmdbId: Int?
    let tvdbId: Int?
    /// `MediaStatus`: 1=UNKNOWN, 2=PENDING, 3=PROCESSING, 4=PARTIALLY_AVAILABLE, 5=AVAILABLE,
    /// 6=BLOCKLISTED, 7=DELETED (Seerr inserted BLOCKLISTED, shifting DELETED from 6 to 7).
    let status: Int?
    let mediaType: String?
}

/// A Seerr `User`. `displayName` is supplied at runtime; the fallbacks mirror the server's own
/// `username || plexUsername || jellyfinUsername || email` resolution for older payloads.
struct SeerrUser: Decodable {
    let id: Int?
    let displayName: String?
    let username: String?
    let plexUsername: String?
    let jellyfinUsername: String?
    let email: String?

    /// A best-effort human label for the requester, never empty.
    var resolvedDisplayName: String {
        for candidate in [displayName, username, plexUsername, jellyfinUsername, email] {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        return "Unknown"
    }
}
