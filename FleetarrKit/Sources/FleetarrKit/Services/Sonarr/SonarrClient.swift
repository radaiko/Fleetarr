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
                id: "queue:\(record.identifier)",
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
