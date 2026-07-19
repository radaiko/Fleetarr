import Foundation

/// Non-secret configuration for one connection to one running service (spec §2, §4).
///
/// This is a pure value type owned by `FleetarrKit`. The app layer persists it via a SwiftData
/// `@Model` (synced through CloudKit, spec §3.5) and maps to/from this struct, keeping the kit
/// free of SwiftData so it stays portable and unit-testable.
///
/// The instance's secret (API key / token) is **never** stored here — it lives in the Keychain,
/// keyed by ``id`` (see ``KeychainStore``). See spec §3.3.
public struct FleetInstance: Sendable, Identifiable, Equatable, Codable, Hashable {
    public var id: UUID
    public var serviceType: ServiceType
    /// User-assigned display label, e.g. "Sonarr (Anime)".
    public var label: String
    /// Scheme + host + port + optional path prefix, e.g. `https://media.example.dev/sonarr`.
    public var baseURLString: String
    /// Per-instance trust override for self-signed / private-CA TLS certs (spec §4).
    public var allowInsecureTLS: Bool
    /// Static headers to inject (HTTP Basic, reverse-proxy headers). Never contains the service
    /// credential itself. Values are secrets-adjacent and must not be logged (spec §4).
    public var extraHeaders: [String: String]
    /// User-added cosmetic warning substrings for SABnzbd, folded into the classifier's defaults so
    /// server-specific "noise" warnings don't count toward the problem badge (spec §6.4). Empty for
    /// non-SABnzbd instances.
    public var cosmeticIgnorePatterns: [String]
    /// Whether the instance participates in refreshes and appears on the dashboard.
    public var isEnabled: Bool
    /// Hidden from the dashboard without being deleted (spec §5). Still refreshable from detail.
    public var isHiddenFromDashboard: Bool
    /// Display order on the dashboard / sidebar (spec §5).
    public var sortOrder: Int

    public init(
        id: UUID = UUID(),
        serviceType: ServiceType,
        label: String,
        baseURLString: String,
        allowInsecureTLS: Bool = false,
        extraHeaders: [String: String] = [:],
        cosmeticIgnorePatterns: [String] = [],
        isEnabled: Bool = true,
        isHiddenFromDashboard: Bool = false,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.serviceType = serviceType
        self.label = label
        self.baseURLString = baseURLString
        self.allowInsecureTLS = allowInsecureTLS
        self.extraHeaders = extraHeaders
        self.cosmeticIgnorePatterns = cosmeticIgnorePatterns
        self.isEnabled = isEnabled
        self.isHiddenFromDashboard = isHiddenFromDashboard
        self.sortOrder = sortOrder
    }

    /// Parsed base URL, or `nil` if the stored string isn't a valid absolute URL.
    public var baseURL: URL? {
        guard let url = URL(string: baseURLString),
              url.scheme != nil, url.host != nil else { return nil }
        return url
    }

    /// True when the base URL uses plain (unencrypted) HTTP — the UI shows a warning (spec §4).
    public var usesPlainHTTP: Bool {
        baseURL?.scheme?.lowercased() == "http"
    }
}
