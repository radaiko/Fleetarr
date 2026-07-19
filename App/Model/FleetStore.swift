import Foundation
import CoreData
import Observation
import SwiftData
import WidgetKit
import FleetarrKit
#if canImport(AppKit)
import AppKit
#endif
#if os(iOS)
import UserNotifications
#endif

/// The app's observable state hub: owns the instance list (from SwiftData), runs concurrent
/// refreshes via `FleetRefresher`, and exposes per-instance status + the fleet summary to the UI.
@MainActor
@Observable
final class FleetStore {
    private let context: ModelContext
    private let keychain: KeychainStore
    private let factory: any FleetServiceFactory

    /// Configured instances, sorted by display order (spec §5).
    private(set) var instances: [FleetInstance] = []
    /// Latest refresh result per instance id.
    private(set) var statuses: [UUID: InstanceStatus] = [:]
    /// Instance ids that currently have a secret in the Keychain (computed on `reload`, so the UI
    /// doesn't hit the Keychain on every render).
    private(set) var configuredInstanceIDs: Set<UUID> = []
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?
    /// Instance ids whose latest refresh couldn't reach them but which still hold a prior good
    /// status — shown stale (last-known-good), not blanked (spec §9.5).
    private(set) var staleInstanceIDs: Set<UUID> = []
    /// When each instance's currently-held status was last successfully refreshed, for the
    /// "updated …" / stale label. Seeded from the on-disk snapshot on launch.
    private(set) var statusUpdatedAt: [UUID: Date] = [:]
    /// Instances whose status is being fetched right now — drives a per-tile spinner while a first
    /// load (no cached status yet) is in flight (spec §5).
    private(set) var refreshingInstanceIDs: Set<UUID> = []

    /// In-memory cache of decrypted secrets so the Keychain data is read at most once per instance
    /// per session — otherwise every refresh/reload re-triggers the macOS keychain-access prompt on
    /// ad-hoc/unsigned builds. `.some(nil)` means "checked, none stored".
    private var credentialCache: [UUID: String?] = [:]

    /// Token for the CloudKit remote-change observer (removed on deinit).
    private var remoteChangeObserver: (any NSObjectProtocol)?

    /// Per-SABnzbd-instance progress memory for the stall detector, carried across refreshes (§6.4).
    private var sabStallState: [UUID: SABnzbdStallDetector.State] = [:]

    #if DEBUG
    /// When true the store is showing built-in demo data (`--demo` launch arg) so `refresh()` is a
    /// no-op — the mock statuses aren't overwritten and no network is hit. Design/screenshot aid
    /// only; compiled out of release builds.
    private(set) var isDemo = false
    #endif

    init(
        context: ModelContext,
        keychain: KeychainStore = KeychainStore(),
        factory: any FleetServiceFactory = DefaultFleetServiceFactory()
    ) {
        self.context = context
        self.keychain = keychain
        self.factory = factory
        reload()
        seedStatusesFromCache()
        observeRemoteChanges()
    }

    /// Seeds `statuses` from the last on-disk snapshot so the dashboard paints cached health +
    /// summary immediately on launch, before the first live refresh returns (spec §3.3 first-paint,
    /// §9.1). The snapshot lives in the App Group, is local-only, and carries no secrets.
    private func seedStatusesFromCache() {
        guard let snapshot = SharedSnapshotStore.read() else { return }
        for snap in snapshot.instances where statuses[snap.id] == nil {
            statuses[snap.id] = InstanceStatus(health: snap.health, summaryLine: snap.summaryLine)
            statusUpdatedAt[snap.id] = snapshot.updatedAt
        }
        if lastRefresh == nil { lastRefresh = snapshot.updatedAt }
    }

    /// CloudKit mirroring persists imported changes and posts `NSPersistentStoreRemoteChange` when
    /// instances added on another device arrive. Re-fetch (and re-poll) so they appear live, without
    /// an app restart — the store-backed `instances` list is otherwise only populated in `init`, so
    /// a backgrounded app would show a stale (often empty) dashboard until relaunch (spec §3.5).
    private func observeRemoteChanges() {
        remoteChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                #if DEBUG
                if self.isDemo { return }
                #endif
                self.reload()
                await self.refresh()
            }
        }
    }

    // MARK: Derived

    /// Instances shown on the dashboard: enabled and not hidden (spec §5).
    var dashboardInstances: [FleetInstance] {
        instances.filter { $0.isEnabled && !$0.isHiddenFromDashboard }
    }

    /// Combined fleet summary for the header + app badge (spec §5).
    var summary: FleetSummary {
        FleetSummary(statuses: dashboardInstances.compactMap { statuses[$0.id] })
    }

    func status(for instance: FleetInstance) -> InstanceStatus? {
        statuses[instance.id]
    }

    // MARK: Loading

    func reload() {
        let descriptor = FetchDescriptor<InstanceRecord>(
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.label)]
        )
        let records = reconcileDuplicates((try? context.fetch(descriptor)) ?? [])
        instances = records.map(\.fleetInstance)
        // Existence check only — attributes-only, so it does NOT decrypt the secret and never
        // prompts (unlike readSecret).
        configuredInstanceIDs = Set(instances.filter { keychain.exists(for: $0.id) }.map(\.id))
    }

    /// Enforces instance uniqueness in app logic, since CloudKit forbids `@Attribute(.unique)`
    /// (spec §3.5). Two devices can each create the "same" instance (same service type + base URL)
    /// while offline and then both sync, producing duplicate tiles. This collapses each such group
    /// to the most-recently-edited record (`updatedAt` tiebreaker), migrating the surviving record's
    /// Keychain secret from a loser if the winner didn't carry one, and deleting the rest. Returns
    /// the surviving records in the input order.
    @discardableResult
    private func reconcileDuplicates(_ records: [InstanceRecord]) -> [InstanceRecord] {
        guard records.count > 1 else { return records }
        var groups: [String: [InstanceRecord]] = [:]
        for record in records {
            groups[Self.dedupKey(record), default: []].append(record)
        }
        guard groups.contains(where: { $0.value.count > 1 }) else { return records }

        var removed = Set<PersistentIdentifier>()
        for group in groups.values where group.count > 1 {
            let ranked = group.sorted { $0.updatedAt > $1.updatedAt }
            let keeper = ranked[0]
            for loser in ranked.dropFirst() {
                if !keychain.exists(for: keeper.id),
                   keychain.exists(for: loser.id),
                   let secret = try? keychain.readSecret(for: loser.id) {
                    try? keychain.save(secret, for: keeper.id)
                }
                try? keychain.delete(for: loser.id)
                statuses[loser.id] = nil
                staleInstanceIDs.remove(loser.id)
                statusUpdatedAt.removeValue(forKey: loser.id)
                credentialCache.removeValue(forKey: loser.id)
                context.delete(loser)
                removed.insert(loser.persistentModelID)
            }
        }
        if !removed.isEmpty { try? context.save() }
        return records.filter { !removed.contains($0.persistentModelID) }
    }

    /// The natural key a duplicate is judged by: service type + normalized base URL (lowercased,
    /// trailing slash trimmed) so `https://host/sonarr` and `https://host/sonarr/` collapse.
    private static func dedupKey(_ record: InstanceRecord) -> String {
        let url = record.baseURLString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalized = url.hasSuffix("/") ? String(url.dropLast()) : url
        return "\(record.serviceTypeRaw)|\(normalized)"
    }

    /// Reads a secret at most once per session, caching the result (including "none stored").
    private func cachedSecret(for id: UUID) -> String? {
        if let cached = credentialCache[id] { return cached }
        let secret = (try? keychain.readSecret(for: id)) ?? nil
        credentialCache[id] = secret
        return secret
    }

    #if DEBUG
    /// Populates the dashboard with representative multi-state demo data (healthy-with-metrics,
    /// warning, error, unreachable) for design work and screenshots, triggered by the `--demo`
    /// launch argument. Sets `isDemo` so `refresh()` becomes a no-op and the mock statuses persist.
    /// Compiled out of release builds.
    func loadDemoData() {
        isDemo = true
        let demo: [(FleetInstance, InstanceStatus)] = [
            (FleetInstance(serviceType: .plex, label: "Plex", baseURLString: "https://plex.demo", sortOrder: 1),
             InstanceStatus(health: .healthy, headline: [
                MetricChip(label: "Streams", value: "3", systemImageName: "play.tv"),
                MetricChip(label: "Transcode", value: "1", systemImageName: "arrow.triangle.2.circlepath"),
             ], summaryLine: "3 streaming now")),
            (FleetInstance(serviceType: .sonarr, label: "Sonarr", baseURLString: "https://sonarr.demo", sortOrder: 2),
             InstanceStatus(health: .healthy, headline: [
                MetricChip(label: "Queue", value: "2", systemImageName: "arrow.down.circle"),
                MetricChip(label: "Missing", value: "14", systemImageName: "tv"),
             ])),
            (FleetInstance(serviceType: .sabnzbd, label: "SABnzbd", baseURLString: "https://sab.demo", sortOrder: 3),
             InstanceStatus(health: .healthy, headline: [
                MetricChip(label: "Speed", value: "24 MB/s", systemImageName: "speedometer"),
                MetricChip(label: "Queue", value: "5", systemImageName: "tray.full"),
             ], summaryLine: "Downloading")),
            (FleetInstance(serviceType: .seerr, label: "Seerr", baseURLString: "https://seerr.demo", sortOrder: 4),
             InstanceStatus(health: .healthy, headline: [
                MetricChip(label: "Pending", value: "4", systemImageName: "tray.and.arrow.down"),
             ], summaryLine: "4 requests pending")),
            (FleetInstance(serviceType: .radarr, label: "Radarr", baseURLString: "https://radarr.demo", sortOrder: 5),
             InstanceStatus(health: .warning, headline: [
                MetricChip(label: "Queue", value: "1", systemImageName: "arrow.down.circle", emphasis: .warning),
                MetricChip(label: "Missing", value: "8", systemImageName: "film.stack"),
             ], problems: [Problem(severity: .warning, title: "Stalled download", detail: "1 item stalled", source: "queue")],
             summaryLine: "1 download stalled")),
            (FleetInstance(serviceType: .prowlarr, label: "Prowlarr", baseURLString: "https://prowlarr.demo", sortOrder: 6),
             InstanceStatus(health: .error, headline: [
                MetricChip(label: "Indexers", value: "1", systemImageName: "exclamationmark.triangle", emphasis: .error),
             ], problems: [Problem(severity: .error, title: "Indexer down", detail: "1 indexer failing", source: "health")],
             summaryLine: "1 indexer failing")),
            (FleetInstance(serviceType: .jellyfin, label: "Jellyfin", baseURLString: "https://jellyfin.demo", sortOrder: 7),
             InstanceStatus(health: .unreachable,
             problems: [Problem(severity: .error, title: "Unreachable", detail: "Connection timed out", source: "connection")],
             summaryLine: "Connection timed out")),
        ]
        instances = demo.map(\.0)
        statuses = Dictionary(uniqueKeysWithValues: demo.map { ($0.0.id, $0.1) })
        configuredInstanceIDs = Set(demo.map { $0.0.id })
        // Mark one healthy instance stale/offline to exercise the last-known-good rendering (§9.5).
        if let sonarr = demo.first(where: { $0.0.serviceType == .sonarr })?.0 {
            staleInstanceIDs.insert(sonarr.id)
            statusUpdatedAt[sonarr.id] = Date(timeIntervalSinceNow: -720)
        }
        lastRefresh = .now
    }
    #endif

    // MARK: Refresh (concurrent, spec §3.2 / §9.2)

    func refresh() async {
        #if DEBUG
        if isDemo { return }
        #endif
        isRefreshing = true
        defer { isRefreshing = false }

        // Re-read the instance list from the store first. It's only otherwise populated in `init`,
        // so instances synced from another device via CloudKit (or edited elsewhere) would stay
        // invisible until an app restart. This is a cheap local fetch and runs on every foreground
        // (`.task(id: scenePhase)`) and pull-to-refresh.
        reload()

        // Read every needed secret once (on the main actor, from the cache), then hand the
        // credential closure a plain dictionary — so it never touches the Keychain (or main-actor
        // state) off-thread, and the keychain prompt can't fire during the refresh loop.
        var credentials: [UUID: String] = [:]
        for instance in dashboardInstances {
            if let secret = cachedSecret(for: instance.id) { credentials[instance.id] = secret }
        }
        refreshingInstanceIDs = Set(dashboardInstances.map(\.id))
        let results = await FleetRefresher.refresh(
            instances: dashboardInstances,
            factory: factory,
            credential: { instance in credentials[instance.id] }
        )
        refreshingInstanceIDs = []
        // Merge results. When a previously-healthy instance just went unreachable, keep its
        // last-known-good status and mark it stale rather than blanking the tile's metrics — the
        // user can still see what it last reported, clearly timestamped (spec §9.5). A genuine
        // status change (or a first-ever unreachable, where there's nothing good to keep) replaces
        // the tile as before. Instances not in this pass keep their previous status untouched.
        for (id, status) in results {
            if status.health == .unreachable,
               let prior = statuses[id], prior.health != .unreachable, prior.health != .unknown {
                staleInstanceIDs.insert(id)
            } else {
                statuses[id] = status
                statusUpdatedAt[id] = .now
                staleInstanceIDs.remove(id)
            }
        }
        lastRefresh = .now

        await detectStalledDownloads()

        Analytics.dashboardRefreshed(instanceCount: dashboardInstances.count)
        let badge = summary.problemBadgeCount
        if badge > 0 { Analytics.problemBadgeShown(count: badge) }

        writeSnapshot()
        updateAppBadge()
    }

    /// Flags SABnzbd downloads that have made no progress for longer than the configured threshold
    /// as a `.warning` (spec §6.4). Stalling is temporal, so it needs progress remembered across
    /// refreshes: this runs one extra lightweight queue fetch per SABnzbd instance that actually has
    /// something queued, advances the per-instance stall memory, and injects a stall warning into
    /// that tile's status (bumping a healthy tile to warning).
    private func detectStalledDownloads() async {
        let minutes = UserDefaults.standard.object(forKey: "stalledThresholdMinutes") as? Int ?? 10
        let threshold = TimeInterval(max(1, minutes) * 60)
        let now = Date.now
        for instance in dashboardInstances where instance.serviceType == .sabnzbd {
            guard let status = statuses[instance.id], status.health != .unreachable else { continue }
            let queueCount = Int(status.headline.first { $0.label == "Queue" }?.value ?? "0") ?? 0
            guard queueCount > 0 else { sabStallState[instance.id] = .init(); continue }
            guard let client = service(for: instance) as? SABnzbdClient,
                  let samples = try? await client.fetchQueueSamples() else { continue }

            let (stalled, newState) = SABnzbdStallDetector.advance(
                sabStallState[instance.id] ?? .init(), samples: samples, now: now, threshold: threshold
            )
            sabStallState[instance.id] = newState
            guard !stalled.isEmpty, var updated = statuses[instance.id] else { continue }
            for id in stalled where !updated.problems.contains(where: { $0.id == "stall:\(id)" }) {
                updated.problems.append(Problem(
                    id: "stall:\(id)",
                    severity: .warning,
                    title: "Stalled download",
                    detail: "No progress for over \(minutes) min",
                    source: "queue"
                ))
            }
            if updated.health == .healthy { updated.health = .warning }
            statuses[instance.id] = updated
        }
    }

    /// Reflects the combined fleet problem count on the app icon (spec §5): the macOS Dock tile
    /// directly, and the iOS app-icon badge via the notification centre. On iOS the badge needs
    /// `.badge` authorization, so it's requested lazily — only the first time there's actually a
    /// problem to show, so a clean fleet never triggers a permission prompt.
    private func updateAppBadge() {
        let count = summary.problemBadgeCount
        #if os(macOS)
        NSApplication.shared.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        #elseif os(iOS)
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                Task { @MainActor in try? await center.setBadgeCount(count) }
            case .notDetermined where count > 0:
                center.requestAuthorization(options: [.badge]) { granted, _ in
                    if granted { Task { @MainActor in try? await center.setBadgeCount(count) } }
                }
            default:
                break
            }
        }
        #endif
    }

    /// Publishes a snapshot to the shared App Group and reloads widget timelines (spec §9.7).
    private func writeSnapshot() {
        let snapshot = FleetSnapshot(
            problemBadgeCount: summary.problemBadgeCount,
            worstHealth: summary.worstHealth,
            unreachableCount: summary.unreachableCount,
            instances: dashboardInstances.map { instance in
                let health = hasStoredSecret(for: instance)
                    ? (status(for: instance)?.health ?? .unknown)
                    : .unknown
                return InstanceSnapshot(
                    id: instance.id,
                    label: instance.label,
                    serviceType: instance.serviceType,
                    health: health,
                    summaryLine: status(for: instance)?.summaryLine
                )
            },
            updatedAt: .now
        )
        SharedSnapshotStore.write(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Builds a live service client for an instance if a secret is stored — used by detail screens
    /// to fetch the activity list. Returns `nil` when the instance is unconfigured or its URL is bad.
    func service(for instance: FleetInstance) -> (any FleetService)? {
        guard let secret = cachedSecret(for: instance.id), !secret.isEmpty else {
            return nil
        }
        return try? factory.makeService(for: instance, credential: secret)
    }

    // MARK: Test connection (spec §4)

    func testConnection(_ instance: FleetInstance, secret: String) async -> ConnectionTestResult {
        let result: ConnectionTestResult
        do {
            let service = try factory.makeService(for: instance, credential: secret)
            result = await service.testConnection()
        } catch {
            result = .failure(error)
        }
        Analytics.connectionTested(instance.serviceType, success: result.isSuccess)
        return result
    }

    // MARK: Write actions (spec §6, Phase 2)

    /// Runs a write action against a freshly-built service, then refreshes the fleet so tiles and
    /// the badge reflect the change. Returns the error to surface, or `nil` on success.
    private func runAction(
        on instance: FleetInstance,
        event: Analytics.WriteAction,
        _ body: (any FleetService) async throws -> Void
    ) async -> FleetError? {
        guard let service = service(for: instance) else { return .unauthorized }
        do {
            try await body(service)
            await refresh()
            Analytics.writeAction(event, instance.serviceType)
            return nil
        } catch let error as FleetError {
            return error
        } catch {
            return .transport("The action failed")
        }
    }

    func removeQueueItem(_ item: ActivityItem, on instance: FleetInstance, blocklist: Bool) async -> FleetError? {
        await runAction(on: instance, event: .queueItemRemoved) { service in
            guard let service = service as? QueueItemRemoving else {
                throw FleetError.transport("Not supported by this service")
            }
            try await service.removeQueueItem(id: item.id, blocklist: blocklist)
        }
    }

    func setQueuePaused(_ paused: Bool, on instance: FleetInstance) async -> FleetError? {
        await runAction(on: instance, event: paused ? .downloadsPaused : .downloadsResumed) { service in
            guard let service = service as? DownloadControlling else {
                throw FleetError.transport("Not supported by this service")
            }
            try await service.setQueuePaused(paused)
        }
    }

    func setItemPaused(_ paused: Bool, _ item: ActivityItem, on instance: FleetInstance) async -> FleetError? {
        await runAction(on: instance, event: paused ? .downloadsPaused : .downloadsResumed) { service in
            guard let service = service as? DownloadControlling else {
                throw FleetError.transport("Not supported by this service")
            }
            try await service.setItemPaused(paused, id: item.id)
        }
    }

    func retryFailedItem(_ item: ActivityItem, on instance: FleetInstance) async -> FleetError? {
        await runAction(on: instance, event: .downloadRetried) { service in
            guard let service = service as? DownloadControlling else {
                throw FleetError.transport("Not supported by this service")
            }
            try await service.retryFailedItem(id: item.id)
        }
    }

    func approveRequest(_ item: ActivityItem, on instance: FleetInstance) async -> FleetError? {
        await runAction(on: instance, event: .requestApproved) { service in
            guard let service = service as? RequestApproving else {
                throw FleetError.transport("Not supported by this service")
            }
            try await service.approveRequest(id: item.id)
        }
    }

    func declineRequest(_ item: ActivityItem, on instance: FleetInstance) async -> FleetError? {
        await runAction(on: instance, event: .requestDeclined) { service in
            guard let service = service as? RequestApproving else {
                throw FleetError.transport("Not supported by this service")
            }
            try await service.declineRequest(id: item.id)
        }
    }

    func terminateSession(_ item: ActivityItem, on instance: FleetInstance) async -> FleetError? {
        await runAction(on: instance, event: .sessionTerminated) { service in
            guard let service = service as? SessionTerminating else {
                throw FleetError.transport("Not supported by this service")
            }
            try await service.terminateSession(id: item.id, reason: "Stopped from Fleetarr")
        }
    }

    // MARK: CRUD

    /// Inserts or updates an instance (upsert by `id`) and stores its secret in the Keychain.
    /// Passing `secret == nil` leaves any existing stored secret untouched.
    func save(_ instance: FleetInstance, secret: String?) {
        let id = instance.id
        let descriptor = FetchDescriptor<InstanceRecord>(predicate: #Predicate { $0.id == id })
        if let existing = try? context.fetch(descriptor).first {
            existing.apply(instance)
            existing.updatedAt = .now
        } else {
            var toInsert = instance
            if toInsert.sortOrder == 0 {
                toInsert.sortOrder = (instances.map(\.sortOrder).max() ?? 0) + 1
            }
            context.insert(InstanceRecord.from(toInsert))
            Analytics.instanceAdded(instance.serviceType)
        }
        try? context.save()

        if let secret, !secret.isEmpty {
            try? keychain.save(secret, for: id)
            credentialCache[id] = secret // cache the just-saved value; next refresh won't re-read
        }
        reload()
    }

    func delete(_ instance: FleetInstance) {
        let id = instance.id
        let descriptor = FetchDescriptor<InstanceRecord>(predicate: #Predicate { $0.id == id })
        if let existing = try? context.fetch(descriptor).first {
            context.delete(existing)
        }
        try? context.save()
        try? keychain.delete(for: id)
        statuses[id] = nil
        staleInstanceIDs.remove(id)
        statusUpdatedAt.removeValue(forKey: id)
        credentialCache.removeValue(forKey: id)
        Analytics.instanceRemoved(instance.serviceType)
        reload()
    }

    /// Reorders instances and persists each one's new `sortOrder` (synced via CloudKit, spec §5).
    func move(from source: IndexSet, to destination: Int) {
        var ordered = instances
        ordered.move(fromOffsets: source, toOffset: destination)
        for (index, instance) in ordered.enumerated() {
            let id = instance.id
            let descriptor = FetchDescriptor<InstanceRecord>(predicate: #Predicate { $0.id == id })
            if let record = try? context.fetch(descriptor).first, record.sortOrder != index {
                record.sortOrder = index
                record.updatedAt = .now
            }
        }
        try? context.save()
        reload()
    }

    /// Whether the tile is showing stale last-known-good data because the latest refresh couldn't
    /// reach the instance (spec §9.5).
    func isStale(_ instance: FleetInstance) -> Bool { staleInstanceIDs.contains(instance.id) }

    /// When the status currently shown for this instance was last successfully refreshed.
    func lastUpdated(for instance: FleetInstance) -> Date? { statusUpdatedAt[instance.id] }

    /// Whether this instance's status is being fetched right now (spec §5).
    func isRefreshing(_ instance: FleetInstance) -> Bool { refreshingInstanceIDs.contains(instance.id) }

    /// Whether a secret is stored for this instance (drives the "not configured" tile state).
    /// Uses the cached set computed on `reload`, so this never hits the Keychain during rendering.
    func hasStoredSecret(for instance: FleetInstance) -> Bool {
        configuredInstanceIDs.contains(instance.id)
    }
}
