import Foundation

/// Sonarr integration (spec §6) — the TV automation *arr. It reports its own health check list and
/// a download queue whose items can be individually flagged, so Fleetarr surfaces both the
/// service-reported health problems and any stuck/failed queue items on one tile.
///
/// Auth is the `X-Api-Key` header applied per call (Sonarr also accepts `?apikey=`, but the header
/// keeps the key out of any logged URL). Base path is `/api/v3` (serves both Sonarr v3 and v4).
public struct SonarrClient: FleetService {
    public let serviceType: ServiceType = .sonarr

    private let context: ServiceContext

    public init(context: ServiceContext) {
        self.context = context
    }

    // MARK: FleetService

    public func testConnection() async -> ConnectionTestResult {
        do {
            let status = try await fetchSystemStatus()
            return .success(version: status.version)
        } catch {
            return .failure(error)
        }
    }

    public func fetchStatus() async throws(FleetError) -> InstanceStatus {
        // system/status doubles as the reachability + auth probe and supplies the version.
        let systemStatus = try await fetchSystemStatus()
        let health = try await fetchHealth()
        let queue = try await fetchQueue()
        // Missing is a secondary count: a failure here must not blank the tile (spec §9.5).
        let missingCount = try? await fetchMissingCount()
        return buildStatus(
            systemStatus: systemStatus,
            health: health,
            queue: queue,
            missingCount: missingCount
        )
    }

    public func fetchActivity() async throws(FleetError) -> [ActivityItem] {
        let queue = try await fetchQueue()
        return (queue.records ?? []).map { record in
            ActivityItem(
                // The bare queue-record id is the DELETE target for removeQueueItem — do not prefix
                // it (the "queue:" prefix belongs only on the Problem id). See spec §6.1.
                id: record.identifier,
                title: record.title ?? "Queue item",
                subtitle: record.downloadClient,
                progress: progress(size: record.size, sizeleft: record.sizeleft),
                status: record.status,
                severity: severity(forTrackedStatus: record.trackedDownloadStatus),
                fields: [
                    .init(label: "State", value: record.trackedDownloadState ?? "—"),
                    .init(label: "Size", value: formatBytes(record.size)),
                    .init(label: "Left", value: formatBytes(record.sizeleft)),
                    .init(label: "ETA", value: record.timeleft ?? "—"),
                ]
            )
        }
    }

    // MARK: Status assembly (pure, unit-testable)

    /// Builds the dashboard status from decoded payloads. Pure so it can be tested directly against
    /// recorded fixtures without a transport (spec §9.8).
    func buildStatus(
        systemStatus: SonarrSystemStatus?,
        health: [SonarrHealth],
        queue: SonarrQueue,
        missingCount: Int?
    ) -> InstanceStatus {
        var problems: [Problem] = []

        // Service-reported health checks: warning/error become problems; ok/notice are ignored.
        for (index, item) in health.enumerated() {
            guard let severity = severity(forHealthType: item.type) else { continue }
            problems.append(Problem(
                id: "health:\(item.source ?? "check"):\(index)",
                severity: severity,
                title: item.message ?? item.source ?? "Health check",
                detail: item.source.map { "Source: \($0)" },
                source: "health"
            ))
        }

        // Queue items flagged by Sonarr's own tracked-download status.
        for record in queue.records ?? [] {
            guard let severity = severity(forTrackedStatus: record.trackedDownloadStatus) else { continue }
            problems.append(Problem(
                id: "queue:\(record.identifier)",
                severity: severity,
                title: record.title ?? "Queue item",
                detail: queueDetail(record),
                source: "queue"
            ))
        }

        let healthState: HealthState = switch problems.worstBadgeSeverity {
        case .error: .error
        case .warning: .warning
        default: .healthy
        }

        // Prefer the authoritative paged total; records is only the fetched page (≤ pageSize).
        let queueCount = queue.totalRecords ?? queue.records?.count ?? 0
        return InstanceStatus(
            health: healthState,
            headline: buildHeadline(queue: queue, queueCount: queueCount, missingCount: missingCount),
            problems: problems,
            summaryLine: buildSummary(queueCount: queueCount, missingCount: missingCount),
            serviceVersion: systemStatus?.version
        )
    }

    private func buildHeadline(queue: SonarrQueue, queueCount: Int, missingCount: Int?) -> [MetricChip] {
        let queueEmphasis: MetricChip.Emphasis = {
            let records = queue.records ?? []
            if records.contains(where: { severity(forTrackedStatus: $0.trackedDownloadStatus) == .error }) {
                return .error
            }
            if records.contains(where: { severity(forTrackedStatus: $0.trackedDownloadStatus) == .warning }) {
                return .warning
            }
            return .normal
        }()

        return [
            MetricChip(
                label: "Missing",
                value: missingCount.map { "\($0)" } ?? "—",
                systemImageName: "questionmark.circle"
            ),
            MetricChip(
                label: "Queue",
                value: "\(queueCount)",
                systemImageName: "tray.and.arrow.down",
                emphasis: queueEmphasis
            ),
        ]
    }

    private func buildSummary(queueCount: Int, missingCount: Int?) -> String {
        var parts: [String] = []
        if queueCount > 0 { parts.append("\(queueCount) in queue") }
        if let missingCount, missingCount > 0 { parts.append("\(missingCount) missing") }
        return parts.isEmpty ? "All caught up" : parts.joined(separator: ", ")
    }

    // MARK: Raw fetches

    /// The API key header, applied per call. The credential is never logged (spec §4).
    private var authHeaders: [String: String] { ["X-Api-Key": context.credential] }

    private func fetchSystemStatus() async throws(FleetError) -> SonarrSystemStatus {
        try await context.fetchJSON(
            SonarrSystemStatus.self,
            path: "/api/v3/system/status",
            headers: authHeaders
        )
    }

    private func fetchHealth() async throws(FleetError) -> [SonarrHealth] {
        try await context.fetchJSON(
            [SonarrHealth].self,
            path: "/api/v3/health",
            headers: authHeaders
        )
    }

    private func fetchQueue() async throws(FleetError) -> SonarrQueue {
        try await context.fetchJSON(
            SonarrQueue.self,
            path: "/api/v3/queue",
            query: [
                URLQueryItem(name: "pageSize", value: "200"),
                URLQueryItem(name: "includeUnknownSeriesItems", value: "true"),
            ],
            headers: authHeaders
        )
    }

    private func fetchMissingCount() async throws(FleetError) -> Int {
        let paging = try await context.fetchJSON(
            SonarrEpisodePaging.self,
            path: "/api/v3/wanted/missing",
            query: [URLQueryItem(name: "pageSize", value: "1")],
            headers: authHeaders
        )
        return paging.totalRecords ?? 0
    }

    /// Upcoming episodes for the detail screen (spec §6). Not part of the dashboard status.
    /// Internal because it returns the internal `SonarrEpisode` wire model.
    func fetchCalendar(start: Date? = nil, end: Date? = nil) async throws(FleetError) -> [SonarrEpisode] {
        let formatter = ISO8601DateFormatter()
        var query: [URLQueryItem] = [URLQueryItem(name: "includeSeries", value: "true")]
        if let start { query.append(URLQueryItem(name: "start", value: formatter.string(from: start))) }
        if let end { query.append(URLQueryItem(name: "end", value: formatter.string(from: end))) }
        return try await context.fetchJSON(
            [SonarrEpisode].self,
            path: "/api/v3/calendar",
            query: query,
            headers: authHeaders
        )
    }

    // MARK: Helpers

    private func severity(forHealthType type: String?) -> Problem.Severity? {
        switch type?.lowercased() {
        case "error": return .error
        case "warning": return .warning
        default: return nil // ok / notice are informational
        }
    }

    private func severity(forTrackedStatus status: String?) -> Problem.Severity? {
        switch status?.lowercased() {
        case "error": return .error
        case "warning": return .warning
        default: return nil // ok
        }
    }

    private func queueDetail(_ record: SonarrQueueRecord) -> String? {
        if let message = record.errorMessage, !message.isEmpty { return message }
        let lines = (record.statusMessages ?? []).flatMap { message -> [String] in
            var parts: [String] = []
            if let title = message.title, !title.isEmpty { parts.append(title) }
            parts.append(contentsOf: message.messages ?? [])
            return parts
        }
        if !lines.isEmpty { return lines.joined(separator: "; ") }
        if let state = record.trackedDownloadState { return "State: \(state)" }
        return nil
    }

    private func progress(size: Double?, sizeleft: Double?) -> Double? {
        guard let size, size > 0 else { return nil }
        let remaining = sizeleft ?? 0
        let done = (size - remaining) / size
        return min(max(done, 0), 1)
    }

    private func formatBytes(_ bytes: Double?) -> String {
        guard let bytes, bytes > 0 else { return "—" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = bytes
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return unit == 0 ? String(format: "%.0f %@", value, units[unit])
                         : String(format: "%.1f %@", value, units[unit])
    }
}

// MARK: - Write actions (spec §6.1)

extension SonarrClient: QueueItemRemoving {
    public func removeQueueItem(id: String, blocklist: Bool) async throws(FleetError) {
        // blocklist=true blocklists the release and triggers an automatic re-search.
        let request = try context.makeRequest(
            path: "/api/v3/queue/\(id)",
            method: "DELETE",
            query: [
                URLQueryItem(name: "removeFromClient", value: "true"),
                URLQueryItem(name: "blocklist", value: blocklist ? "true" : "false"),
            ],
            headers: authHeaders
        )
        _ = try await context.send(request)
    }
}

// MARK: - Detail-screen listings (spec §6.1)

/// Secondary read-only lists for the Sonarr detail screen: upcoming episodes, recent history, and
/// wanted-but-missing episodes. Each maps its wire model onto the generic ``ActivityItem`` so the
/// shared detail UI renders them uniformly. All reuse the client's `authHeaders` and helpers; the
/// API key is never logged (spec §4).
extension SonarrClient: UpcomingListing, HistoryListing, MissingListing {
    /// Episodes airing within the next `days` days (`GET /api/v3/calendar`, a bare array). Reuses
    /// the existing internal `fetchCalendar(start:end:)`, which already sets `includeSeries=true`.
    public func fetchUpcoming(days: Int) async throws(FleetError) -> [ActivityItem] {
        let start = Date()
        // Calendar returns a bare, unpaged array; bound it by the look-ahead window and then cap.
        let end = start.addingTimeInterval(Double(max(days, 0)) * 86_400)
        let episodes = try await fetchCalendar(start: start, end: end)
        return episodes.prefix(Self.listingCap).map { episode in
            let air = dateOnly(episode.airDateUtc) ?? dateOnly(episode.airDate)
            return ActivityItem(
                id: episodeStableId(episode, prefix: "upcoming"),
                title: episodeTitle(episode),
                subtitle: air,
                status: (episode.hasFile ?? false) ? "Downloaded" : "Upcoming",
                fields: [
                    .init(label: "Air date", value: air ?? "—"),
                    .init(label: "Monitored", value: monitoredText(episode.monitored)),
                ]
            )
        }
    }

    /// The most recent grab/import/failure events (`GET /api/v3/history`, newest first). Failures
    /// (`downloadFailed` / `importFailed`) carry `.error` severity so the UI can surface them.
    public func fetchRecentHistory() async throws(FleetError) -> [ActivityItem] {
        let paging = try await context.fetchJSON(
            SonarrHistoryPaging.self,
            path: "/api/v3/history",
            query: [
                URLQueryItem(name: "page", value: "1"),
                URLQueryItem(name: "pageSize", value: String(Self.listingCap)),
                URLQueryItem(name: "sortKey", value: "date"),
                URLQueryItem(name: "sortDirection", value: "descending"),
            ],
            headers: authHeaders
        )
        return (paging.records ?? []).prefix(Self.listingCap).map { record in
            ActivityItem(
                id: "history:\(record.identifier)",
                title: record.sourceTitle ?? "History event",
                subtitle: dateOnly(record.date),
                status: readableEventType(record.eventType),
                severity: historySeverity(record.eventType),
                fields: [
                    .init(label: "Quality", value: record.quality?.name ?? "—"),
                    .init(label: "Indexer", value: record.data?["indexer"] ?? "—"),
                ]
            )
        }
    }

    /// Wanted-but-missing monitored episodes (`GET /api/v3/wanted/missing`), browsable rather than
    /// just a count. `includeSeries=true` so each row can show its series title.
    public func fetchMissing() async throws(FleetError) -> [ActivityItem] {
        let paging = try await context.fetchJSON(
            SonarrEpisodePaging.self,
            path: "/api/v3/wanted/missing",
            query: [
                URLQueryItem(name: "page", value: "1"),
                URLQueryItem(name: "pageSize", value: String(Self.listingCap)),
                URLQueryItem(name: "sortKey", value: "airDateUtc"),
                URLQueryItem(name: "monitored", value: "true"),
                URLQueryItem(name: "includeSeries", value: "true"),
            ],
            headers: authHeaders
        )
        return (paging.records ?? []).prefix(Self.listingCap).map { episode in
            ActivityItem(
                id: episodeStableId(episode, prefix: "missing"),
                title: episodeTitle(episode),
                subtitle: dateOnly(episode.airDateUtc) ?? dateOnly(episode.airDate),
                status: "Missing",
                fields: [
                    .init(label: "Monitored", value: monitoredText(episode.monitored)),
                ]
            )
        }
    }
}

// MARK: - Listing helpers (private, file-scoped)

private extension SonarrClient {
    /// Result cap applied to every detail-screen list (spec: cap ~30).
    static var listingCap: Int { 30 }

    /// "<series> — S02E05 <episode title>", degrading gracefully as fields go missing.
    func episodeTitle(_ episode: SonarrEpisode) -> String {
        let series = episode.series?.title ?? "Unknown series"
        var code = ""
        if let season = episode.seasonNumber, let number = episode.episodeNumber {
            code = String(format: "S%02dE%02d", season, number)
        } else if let season = episode.seasonNumber {
            code = String(format: "S%02d", season)
        }
        let name = episode.title ?? ""
        var right = code
        if !name.isEmpty {
            right = right.isEmpty ? name : "\(code) \(name)"
        }
        return right.isEmpty ? series : "\(series) — \(right)"
    }

    /// A stable per-list activity id, tolerant of a missing episode `id`.
    func episodeStableId(_ episode: SonarrEpisode, prefix: String) -> String {
        if let id = episode.id { return "\(prefix):\(id)" }
        return "\(prefix):\(episode.seriesId ?? 0):\(episode.seasonNumber ?? 0):\(episode.episodeNumber ?? 0)"
    }

    /// The `yyyy-MM-dd` portion of an ISO-8601 date or date-time (the part before `T`). Avoids a
    /// timezone-dependent reformat, keeping the value deterministic for tests.
    func dateOnly(_ iso: String?) -> String? {
        guard let iso, !iso.isEmpty else { return nil }
        if let separator = iso.firstIndex(of: "T") { return String(iso[..<separator]) }
        return iso
    }

    func monitoredText(_ monitored: Bool?) -> String {
        guard let monitored else { return "—" }
        return monitored ? "Yes" : "No"
    }

    /// A short, human-readable label for a Sonarr history `eventType`.
    func readableEventType(_ eventType: String?) -> String {
        guard let eventType else { return "Unknown" }
        switch eventType.lowercased() {
        case "grabbed": return "Grabbed"
        case "seriesfolderimported", "downloadfolderimported": return "Imported"
        case "downloadfailed": return "Download failed"
        case "importfailed": return "Import failed"
        case "episodefiledeleted": return "File deleted"
        case "episodefilerenamed": return "File renamed"
        case "downloadignored": return "Download ignored"
        case "unknown": return "Unknown"
        // A future/unknown event type: humanize the original camelCase rather than drop it.
        default: return humanizeCamelCase(eventType)
        }
    }

    func historySeverity(_ eventType: String?) -> Problem.Severity? {
        switch eventType?.lowercased() {
        case "downloadfailed", "importfailed": return .error
        default: return nil
        }
    }

    /// "downloadFolderImported" → "Download folder imported", for event types not in the map above.
    func humanizeCamelCase(_ text: String) -> String {
        var result = ""
        for (index, character) in text.enumerated() {
            if character.isUppercase, index != 0 { result.append(" ") }
            result.append(index == 0 ? Character(character.uppercased()) : character)
        }
        return result
    }
}
