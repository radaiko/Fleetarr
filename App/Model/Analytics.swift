import Foundation
import Aptabase
import FleetarrKit

/// Thin wrapper over the self-hosted Aptabase instance (spec §3.4).
///
/// Tracks **feature-usage and app-health events only** — never a media title, username, requester,
/// server hostname/URL, API key, or free-text error. Only enum-like categories (e.g. a service
/// type's raw value) and counts are ever sent as properties. Respects the analytics opt-out.
enum Analytics {
    /// Fleetarr's own app key on the shared self-hosted instance (spec §3.4). The `SH` segment
    /// selects self-hosted mode; the host below is where events are ingested.
    private static let appKey = "A-SH-1882993583"
    private static let host = "https://hetzner-server-1.ibex-dory.ts.net"

    /// Initialize the SDK once at launch. Safe to call regardless of the opt-out — nothing is sent
    /// until `track` is called, and `track` is gated on the preference.
    static func start() {
        Aptabase.shared.initialize(appKey: appKey, with: InitOptions(host: host))
    }

    private static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "analyticsEnabled") as? Bool ?? true
    }

    private static func track(_ event: String, _ properties: [String: Any] = [:]) {
        guard isEnabled else { return }
        Aptabase.shared.trackEvent(event, with: properties)
    }

    // MARK: Event taxonomy (strings/numbers only, no sensitive values)

    static func appLaunched() {
        track("app_launched")
    }

    static func instanceAdded(_ serviceType: ServiceType) {
        track("instance_added", ["service_type": serviceType.rawValue])
    }

    static func instanceRemoved(_ serviceType: ServiceType) {
        track("instance_removed", ["service_type": serviceType.rawValue])
    }

    static func dashboardRefreshed(instanceCount: Int) {
        track("dashboard_refreshed", ["count": instanceCount])
    }

    static func problemBadgeShown(count: Int) {
        track("problem_badge_shown", ["count": count])
    }

    static func connectionTested(_ serviceType: ServiceType, success: Bool) {
        track("connection_tested", ["service_type": serviceType.rawValue, "success": success])
    }

    static func writeAction(_ action: WriteAction, _ serviceType: ServiceType) {
        track(action.rawValue, ["service_type": serviceType.rawValue])
    }

    enum WriteAction: String {
        case queueItemRemoved = "queue_item_removed"
        case requestApproved = "request_approved"
        case requestDeclined = "request_declined"
        case sessionTerminated = "session_terminated"
        case downloadsPaused = "downloads_paused"
        case downloadsResumed = "downloads_resumed"
    }
}
