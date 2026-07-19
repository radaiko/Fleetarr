import Foundation

/// One of the seven media-stack services Fleetarr can monitor.
///
/// Each service type may have zero, one, or several configured ``FleetInstance`` values
/// (e.g. separate Sonarr instances for TV vs. anime). See spec §1, §4.
public enum ServiceType: String, Codable, Sendable, CaseIterable, Identifiable, Hashable {
    case sonarr
    case radarr
    case prowlarr
    case seerr
    case sabnzbd
    case plex
    case jellyfin

    public var id: String { rawValue }

    /// Human-facing name for tiles, labels, and VoiceOver.
    public var displayName: String {
        switch self {
        case .sonarr: return "Sonarr"
        case .radarr: return "Radarr"
        case .prowlarr: return "Prowlarr"
        case .seerr: return "Seerr"
        case .sabnzbd: return "SABnzbd"
        case .plex: return "Plex"
        case .jellyfin: return "Jellyfin"
        }
    }

    /// SF Symbol used to represent the service in the UI.
    public var systemImageName: String {
        switch self {
        case .sonarr: return "tv"
        case .radarr: return "film"
        case .prowlarr: return "magnifyingglass"
        case .seerr: return "tray.and.arrow.down"
        case .sabnzbd: return "arrow.down.circle"
        case .plex: return "play.rectangle"
        case .jellyfin: return "play.circle"
        }
    }

    /// How this service expects Fleetarr to authenticate (spec §4).
    public var credentialKind: CredentialKind {
        switch self {
        case .sonarr, .radarr, .prowlarr, .sabnzbd, .jellyfin:
            return .apiKey
        case .plex:
            return .plexOAuthToken
        case .seerr:
            // Seerr accepts an API key (X-Api-Key) or a local login; Fleetarr uses the API key.
            return .apiKey
        }
    }

    /// The category of activity a service's detail screen primarily shows (spec §6, §8).
    public var primaryActivityNoun: String {
        switch self {
        case .sonarr, .radarr, .sabnzbd: return "Queue"
        case .prowlarr: return "Indexers"
        case .seerr: return "Requests"
        case .plex, .jellyfin: return "Streams"
        }
    }
}

/// The kind of secret an instance stores in the Keychain.
public enum CredentialKind: String, Codable, Sendable, Hashable {
    /// A static API key sent as a header or query parameter.
    case apiKey
    /// A token obtained via Plex's plex.tv PIN OAuth flow.
    case plexOAuthToken
}
