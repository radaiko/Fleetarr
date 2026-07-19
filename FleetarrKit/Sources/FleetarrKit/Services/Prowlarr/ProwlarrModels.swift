import Foundation

// Decodable shapes for the Prowlarr (Servarr-family) REST API rooted at `/api/v1`.
//
// Prowlarr returns real JSON objects/arrays (not string-encoded numbers like SABnzbd), and health
// / indexerstatus endpoints return an *empty array* when everything is fine — an empty array is the
// healthy state, not an error (research §errorHandling). Timestamps are kept as `String?` rather
// than `Date` so an unexpected format never fails the whole decode; the client parses them lazily.
// All non-identifying fields are optional because real servers omit fields across versions.

/// `GET /api/v1/system/status` — a single `SystemResource`. Used for the version + auth probe.
struct ProwlarrSystemStatus: Decodable {
    let appName: String?
    let instanceName: String?
    let version: String?
    let branch: String?
    let osName: String?
    let packageVersion: String?
    let authentication: String?
    let runtimeVersion: String?
}

/// One entry of `GET /api/v1/health` — the endpoint returns ONLY non-OK checks (empty `[]` = all OK).
struct ProwlarrHealthResource: Decodable {
    let id: Int?
    let source: String?
    /// `HealthCheckResult` serialized camelCase: "ok" | "notice" | "warning" | "error".
    let type: String?
    let message: String?
    let wikiUrl: String?
}

/// A per-provider notice attached to an indexer or application (`ProviderMessage`).
struct ProwlarrProviderMessage: Decodable {
    let message: String?
    /// "info" | "warning" | "error".
    let type: String?
}

/// One entry of `GET /api/v1/indexer` — the configured indexers with their on/off toggle and,
/// when failing, a nested ``ProwlarrIndexerStatus``.
struct ProwlarrIndexer: Decodable {
    let id: Int
    let name: String
    let enable: Bool?
    /// `protocol` is a reserved word in Swift, mapped via CodingKeys.
    let protocolName: String?
    let privacy: String?
    let priority: Int?
    /// Per-indexer notice; carries the human-readable failure reason when the indexer is failing.
    let message: ProwlarrProviderMessage?
    /// Populated (non-null) when the indexer is auto-disabled / backing off; null when healthy.
    let status: ProwlarrIndexerStatus?

    enum CodingKeys: String, CodingKey {
        case id, name, enable, privacy, priority, message, status
        case protocolName = "protocol"
    }
}

/// `GET /api/v1/indexerstatus` — THE failing-indexer signal. The endpoint returns ONLY currently
/// blocked/backed-off providers; an empty array means every enabled indexer is healthy. This same
/// shape also appears nested inside ``ProwlarrIndexer/status``.
struct ProwlarrIndexerStatus: Decodable {
    let id: Int?
    /// Join key back to ``ProwlarrIndexer/id``.
    let indexerId: Int?
    /// UTC ISO-8601; if in the future, the indexer is auto-disabled/backing off.
    let disabledTill: String?
    let mostRecentFailure: String?
    /// Start of the current failure streak.
    let initialFailure: String?

    /// A non-null `disabledTill` / recent failure means the indexer is FAILING (task §6.2).
    var isFailing: Bool {
        func present(_ value: String?) -> Bool {
            (value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        }
        return present(disabledTill) || present(mostRecentFailure) || present(initialFailure)
    }
}

/// A configured downstream application Prowlarr syncs indexers to (Sonarr/Radarr/…), from
/// `GET /api/v1/applications` (spec §6.2).
struct ProwlarrApplication: Decodable {
    let id: Int?
    let name: String?
    /// "disabled" | "addOnly" | "fullSync" — how Prowlarr pushes indexer changes to this app.
    let syncLevel: String?
    let implementationName: String?
}
