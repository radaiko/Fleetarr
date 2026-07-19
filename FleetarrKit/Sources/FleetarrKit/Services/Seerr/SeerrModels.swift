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

/// The media the request targets. The human title/poster is resolved separately via Seerr's own
/// `/movie/{tmdbId}` or `/tv/{tmdbId}` detail endpoint (``SeerrMediaDetail``); only the identifiers
/// are on the request itself.
struct SeerrMedia: Decodable {
    let id: Int?
    let tmdbId: Int?
    let tvdbId: Int?
    /// `MediaStatus`: 1=UNKNOWN, 2=PENDING, 3=PROCESSING, 4=PARTIALLY_AVAILABLE, 5=AVAILABLE,
    /// 6=BLOCKLISTED, 7=DELETED (Seerr inserted BLOCKLISTED, shifting DELETED from 6 to 7).
    let status: Int?
    let mediaType: String?
}

/// The subset of Seerr's `/movie/{tmdbId}` or `/tv/{tmdbId}` detail used to show a request's real
/// title + poster (spec §6.3). Movies carry `title`, TV carries `name`.
struct SeerrMediaDetail: Decodable {
    let title: String?
    let name: String?
    let posterPath: String?

    var displayTitle: String? {
        let candidate = title ?? name
        guard let candidate, !candidate.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return candidate
    }
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

/// The media server a Seerr instance is backed by (spec §6.3 — feature-detect, never assume).
/// Note the enum values: PLEX=1, JELLYFIN=2, EMBY=3, NOT_CONFIGURED=4 (not 0).
public enum SeerrMediaServer: Int, Sendable, Equatable {
    case plex = 1
    case jellyfin = 2
    case emby = 3
    case notConfigured = 4

    public var displayName: String {
        switch self {
        case .plex: "Plex"
        case .jellyfin: "Jellyfin"
        case .emby: "Emby"
        case .notConfigured: "Not configured"
        }
    }
}

/// `GET /api/v1/settings/public` (unauthenticated) — used to feature-detect the backing server.
struct SeerrPublicSettings: Decodable {
    let mediaServerType: Int?
}
