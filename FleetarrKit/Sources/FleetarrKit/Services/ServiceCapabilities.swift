import Foundation

// Optional write-action capabilities (spec §6, Phase 2). A service conforms to a capability only
// where its API supports it; the UI feature-detects via `as?` and offers the action when present.
// Actions mutate the user's stack, so callers should confirm destructive ones first.

/// Removing a stuck/failed item from the download queue (Sonarr, Radarr, SABnzbd; spec §6.1, §6.4).
public protocol QueueItemRemoving: FleetService {
    /// Removes the queue item with the given id (the `ActivityItem.id` of a queue row).
    /// When `blocklist` is true the release is blocklisted so it isn't grabbed again — for
    /// Sonarr/Radarr this also triggers an automatic re-search. Ignored by SABnzbd.
    func removeQueueItem(id: String, blocklist: Bool) async throws(FleetError)
}

/// Download-client controls specific to SABnzbd (spec §6.4).
public protocol DownloadControlling: FleetService {
    /// Pause or resume the entire queue.
    func setQueuePaused(_ paused: Bool) async throws(FleetError)
    /// Pause or resume a single queue item.
    func setItemPaused(_ paused: Bool, id: String) async throws(FleetError)
    /// Retry a failed history item.
    func retryFailedItem(id: String) async throws(FleetError)
}

/// Approving/declining pending requests (Seerr; spec §6.3).
public protocol RequestApproving: FleetService {
    func approveRequest(id: String) async throws(FleetError)
    func declineRequest(id: String) async throws(FleetError)
}

/// Terminating an active playback session (Plex, Jellyfin; spec §6.5, §6.6).
public protocol SessionTerminating: FleetService {
    /// Terminates the session with the given id (the `ActivityItem.id` of a stream row), with an
    /// optional reason shown to the client that gets stopped.
    func terminateSession(id: String, reason: String?) async throws(FleetError)
}
