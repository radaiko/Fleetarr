import Foundation

// Secondary read-only lists a service can provide for its detail screen (spec §6). Each returns the
// generic `ActivityItem` so the detail UI renders them uniformly; the screen feature-detects with
// `as?` and shows a section per capability it finds.

/// Upcoming / calendar items within a look-ahead window (Sonarr, Radarr; spec §6.1).
public protocol UpcomingListing: FleetService {
    func fetchUpcoming(days: Int) async throws(FleetError) -> [ActivityItem]
}

/// Recent history — grabs/imports/failures for the *arr apps, completed/failed downloads for
/// SABnzbd (spec §6.1, §6.4). Failures should carry `.error` severity so the UI can surface them.
public protocol HistoryListing: FleetService {
    func fetchRecentHistory() async throws(FleetError) -> [ActivityItem]
}

/// Wanted-but-missing items, browsable rather than just a count (Sonarr, Radarr; spec §6.1).
public protocol MissingListing: FleetService {
    func fetchMissing() async throws(FleetError) -> [ActivityItem]
}

/// Recently-added library items (Plex, Jellyfin; spec §6.5, §6.6).
public protocol RecentlyAddedListing: FleetService {
    func fetchRecentlyAdded() async throws(FleetError) -> [ActivityItem]
}

/// Prowlarr's configured downstream applications (Sonarr/Radarr/…) and their indexer-sync level, so
/// the detail screen can show what Prowlarr syncs to (spec §6.2). Sync *failures* additionally
/// surface as health-check problems on the tile; this is the "what's configured" companion view.
public protocol ApplicationSyncListing: FleetService {
    func fetchApplications() async throws(FleetError) -> [ActivityItem]
}
