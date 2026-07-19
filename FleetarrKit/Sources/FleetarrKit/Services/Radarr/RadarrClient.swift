import Foundation

/// Radarr integration (spec §6) — the movie manager. Structurally near-identical to Sonarr v3 but
/// movie-oriented. Auth is the `X-Api-Key` HTTP header; the REST API lives under `/api/v3`.
///
/// `GET /api/v3/system/status` is the cheap authenticated call used for testConnection: a bad key
/// returns 401 (mapped to `.unauthorized`) and an unreachable host surfaces the real transport
/// failure, rather than the silent 200 that the anonymous `/ping` gives. The dashboard status is
/// built from `/health` (service-reported problems) + `/queue` (stuck/failed downloads), with the
/// headline showing the count of wanted-but-missing movies and the live queue size.
public struct RadarrClient: FleetService {
    public let serviceType: ServiceType = .radarr

    private let context: ServiceContext

    public init(context: ServiceContext) {
        self.context = context
    }

    // MARK: FleetService

    public func testConnection() async -> ConnectionTestResult {
        do {
            let system = try await fetchSystemStatus()
            return .success(version: system.version)
        } catch {
            return .failure(error)
        }
    }

    public func fetchStatus() async throws(FleetError) -> InstanceStatus {
        // system/status is the mandatory reachability + auth probe: if it fails, the tile is
        // unreachable/errored. Everything else is best-effort so a single failing auxiliary
        // endpoint must not blank the tile (spec §9.5).
        let system = try await fetchSystemStatus()
        let health = (try? await fetchHealth()) ?? []
        let queueResponse = try? await fetchQueue()
        let missingCount = try? await fetchMissingCount()
        return buildStatus(
            system: system,
            health: health,
            queue: queueResponse?.records ?? [],
            queueTotal: queueResponse?.totalRecords,
            missingCount: missingCount
        )
    }

    public func fetchActivity() async throws(FleetError) -> [ActivityItem] {
        let records = try await fetchQueueRecords()
        return records.map { record in
            ActivityItem(
                id: record.id.map { String($0) } ?? UUID().uuidString,
                title: record.movie?.title ?? record.title ?? "Unknown",
                subtitle: record.movie != nil ? record.title : record.indexer,
                progress: progress(for: record),
                status: record.status,
                severity: severity(forTrackedStatus: record.trackedDownloadStatus),
                fields: [
                    .init(label: "Time left", value: record.timeleft ?? "—"),
                    .init(label: "Client", value: record.downloadClient ?? "—"),
                    .init(label: "Indexer", value: record.indexer ?? "—"),
                ]
            )
        }
    }

    // MARK: Status assembly (pure, unit-testable)

    /// Builds the dashboard status from the decoded payloads. Pure so it can be tested directly
    /// against recorded fixtures without a transport (spec §9.8).
    func buildStatus(
        system: RadarrSystemStatus,
        health: [RadarrHealthResource],
        queue: [RadarrQueueRecord],
        queueTotal: Int? = nil,
        missingCount: Int?
    ) -> InstanceStatus {
        var problems: [Problem] = []

        // Service-reported health checks (spec §6): notice → cosmetic, warning/error map directly.
        for check in health {
            guard let severity = severity(forHealthType: check.type) else { continue }
            problems.append(Problem(
                id: healthProblemID(for: check),
                severity: severity,
                title: check.source ?? "Health check",
                detail: check.message,
                source: "health"
            ))
        }

        // Queue items in a bad state (trackedDownloadStatus warning/error).
        var queueWorst: Problem.Severity?
        for record in queue {
            guard let severity = severity(forTrackedStatus: record.trackedDownloadStatus) else { continue }
            queueWorst = max(queueWorst ?? severity, severity)
            problems.append(Problem(
                id: queueProblemID(for: record),
                severity: severity,
                title: record.movie?.title ?? record.title ?? "Download",
                detail: queueDetail(for: record),
                source: "queue"
            ))
        }

        let healthState: HealthState = switch problems.worstBadgeSeverity {
        case .error: .error
        case .warning: .warning
        default: .healthy
        }

        // Prefer the authoritative paged total; `queue` is only the fetched page (≤ pageSize).
        let queueCount = queueTotal ?? queue.count
        return InstanceStatus(
            health: healthState,
            headline: buildHeadline(queueCount: queueCount, missingCount: missingCount, queueWorst: queueWorst),
            problems: problems,
            summaryLine: buildSummary(queueCount: queueCount, missingCount: missingCount, problems: problems),
            serviceVersion: system.version
        )
    }

    private func buildHeadline(queueCount: Int, missingCount: Int?, queueWorst: Problem.Severity?) -> [MetricChip] {
        let queueEmphasis: MetricChip.Emphasis = switch queueWorst {
        case .error: .error
        case .warning: .warning
        default: .normal
        }
        return [
            MetricChip(label: "Missing", value: "\(missingCount ?? 0)", systemImageName: "film.stack"),
            MetricChip(label: "Queue", value: "\(queueCount)", systemImageName: "arrow.down.circle", emphasis: queueEmphasis),
        ]
    }

    private func buildSummary(queueCount: Int, missingCount: Int?, problems: [Problem]) -> String {
        switch problems.worstBadgeSeverity {
        case .error: return "Problems need attention"
        case .warning: return "Warnings present"
        default: break
        }
        var parts: [String] = []
        if let missingCount, missingCount > 0 { parts.append("\(missingCount) missing") }
        if queueCount > 0 { parts.append(queueCount == 1 ? "1 downloading" : "\(queueCount) downloading") }
        return parts.isEmpty ? "All caught up" : parts.joined(separator: " · ")
    }

    // MARK: Raw fetches

    private var authHeaders: [String: String] {
        ["X-Api-Key": context.credential]
    }

    private func fetchSystemStatus() async throws(FleetError) -> RadarrSystemStatus {
        try await context.fetchJSON(
            RadarrSystemStatus.self,
            path: "/api/v3/system/status",
            headers: authHeaders
        )
    }

    private func fetchHealth() async throws(FleetError) -> [RadarrHealthResource] {
        try await context.fetchJSON(
            [RadarrHealthResource].self,
            path: "/api/v3/health",
            headers: authHeaders
        )
    }

    private func fetchQueue() async throws(FleetError) -> RadarrQueueResponse {
        try await context.fetchJSON(
            RadarrQueueResponse.self,
            path: "/api/v3/queue",
            query: [
                URLQueryItem(name: "pageSize", value: "100"),
                URLQueryItem(name: "includeMovie", value: "true"),
            ],
            headers: authHeaders
        )
    }

    private func fetchQueueRecords() async throws(FleetError) -> [RadarrQueueRecord] {
        try await fetchQueue().records ?? []
    }

    private func fetchMissingCount() async throws(FleetError) -> Int {
        // pageSize=1 keeps this cheap — we only need `totalRecords` for the headline.
        let response = try await context.fetchJSON(
            RadarrMissingResponse.self,
            path: "/api/v3/wanted/missing",
            query: [URLQueryItem(name: "pageSize", value: "1")],
            headers: authHeaders
        )
        return response.totalRecords ?? 0
    }

    // MARK: Helpers

    /// Stable-ish problem id for a health row: prefer the numeric id, fall back to the source.
    private func healthProblemID(for check: RadarrHealthResource) -> String {
        if let id = check.id { return "health:\(id)" }
        return "health:\(check.source ?? UUID().uuidString)"
    }

    /// Stable-ish problem id for a queue row: the queue-item id, or a random id if absent.
    private func queueProblemID(for record: RadarrQueueRecord) -> String {
        if let id = record.id { return "queue:\(id)" }
        return "queue:\(UUID().uuidString)"
    }

    private func severity(forHealthType type: String?) -> Problem.Severity? {
        switch type?.lowercased() {
        case "error": return .error
        case "warning": return .warning
        case "notice": return .cosmetic
        default: return nil // "ok" or unknown → not a problem
        }
    }

    private func severity(forTrackedStatus status: String?) -> Problem.Severity? {
        switch status?.lowercased() {
        case "error": return .error
        case "warning": return .warning
        default: return nil // "ok" or unknown → not a problem
        }
    }

    private func queueDetail(for record: RadarrQueueRecord) -> String {
        if let message = record.errorMessage, !message.isEmpty { return message }
        let messages = (record.statusMessages ?? []).flatMap { statusMessage -> [String] in
            let lines = statusMessage.messages ?? []
            return lines.isEmpty ? [statusMessage.title].compactMap { $0 } : lines
        }
        if !messages.isEmpty { return messages.joined(separator: "; ") }
        return "Queue status: \(record.status ?? record.trackedDownloadStatus ?? "unknown")"
    }

    private func progress(for record: RadarrQueueRecord) -> Double? {
        guard let size = record.size, size > 0, let left = record.sizeleft else { return nil }
        let done = (size - left) / size
        return min(max(done, 0), 1)
    }
}

// MARK: - Write actions (spec §6.1)

extension RadarrClient: QueueItemRemoving {
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
