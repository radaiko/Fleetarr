import Foundation

/// Prowlarr integration (spec §6, task §6.2) — Prowlarr is the indexer manager, so its whole reason
/// to exist on the dashboard is: *which indexers are failing, and why?*
///
/// The key requirement is to count failing indexers and surface each one with its last error /
/// disabled-until time. The authoritative signal is `GET /api/v1/indexerstatus`, which returns ONLY
/// currently blocked/backed-off providers (empty array = all healthy); we join those to
/// `GET /api/v1/indexer` (which carries the `enable` toggle, name, and the human-readable failure
/// message) by `indexerId`, and fall back to each indexer's nested `status` object so a failing
/// indexer is still detected even if the `indexerstatus` call itself fails.
///
/// Auth is the `X-Api-Key` request header, applied by this client on every call. The credential is
/// never logged (spec §4).
public struct ProwlarrClient: FleetService {
    public let serviceType: ServiceType = .prowlarr

    private let context: ServiceContext

    public init(context: ServiceContext) {
        self.context = context
    }

    // MARK: FleetService

    public func testConnection() async -> ConnectionTestResult {
        do {
            // system/status is the definitive auth+reachability probe: 200 = key OK, 401 = bad key
            // (research). /ping is unauthenticated and can't validate the credential.
            let status = try await fetchSystemStatus()
            return .success(version: status.version)
        } catch {
            return .failure(error)
        }
    }

    public func fetchStatus() async throws(FleetError) -> InstanceStatus {
        // The indexer list is the primary, required call — it proves reachability + auth and alone
        // carries enough (nested `status`) to detect failures.
        let indexers = try await fetchIndexers()
        // The rest are best-effort so a single endpoint hiccup never blanks the whole tile (spec §9.5).
        let statuses = (try? await fetchIndexerStatuses()) ?? []
        let health = (try? await fetchHealth()) ?? []
        let version = (try? await fetchSystemStatus())?.version
        return buildStatus(indexers: indexers, indexerStatuses: statuses, health: health, version: version)
    }

    public func fetchActivity() async throws(FleetError) -> [ActivityItem] {
        let indexers = try await fetchIndexers()
        let statuses = (try? await fetchIndexerStatuses()) ?? []
        let statusByIndexer = failingStatusByIndexer(indexers: indexers, statuses: statuses)

        return indexers.map { indexer in
            let status = statusByIndexer[indexer.id]
            let isFailing = status != nil
            let isDisabled = indexer.enable == false

            var fields: [ActivityItem.Field] = []
            if let proto = indexer.protocolName, !proto.isEmpty {
                fields.append(.init(label: "Protocol", value: proto.capitalized))
            }
            if let privacy = indexer.privacy, !privacy.isEmpty {
                fields.append(.init(label: "Privacy", value: privacy.capitalized))
            }
            if let priority = indexer.priority {
                fields.append(.init(label: "Priority", value: "\(priority)"))
            }
            if let till = disabledUntilText(status?.disabledTill) {
                fields.append(.init(label: "Backoff", value: till))
            }

            let statusText = isFailing ? "Failing" : (isDisabled ? "Disabled" : "OK")
            return ActivityItem(
                id: "indexer:\(indexer.id)",
                title: indexer.name,
                subtitle: indexer.message?.message,
                status: statusText,
                severity: isFailing ? .error : nil,
                fields: fields
            )
        }
    }

    // MARK: Status assembly (pure, unit-testable)

    /// Builds the dashboard status from the decoded indexer list, indexer-status list, and health
    /// list. Pure so it can be tested directly against recorded fixtures without a transport
    /// (spec §9.8), mirroring `SABnzbdClient.buildStatus`.
    func buildStatus(
        indexers: [ProwlarrIndexer],
        indexerStatuses: [ProwlarrIndexerStatus],
        health: [ProwlarrHealthResource],
        version: String?
    ) -> InstanceStatus {
        var problems: [Problem] = []

        // One error Problem per failing indexer (task §6.2) — title = indexer name, detail = last
        // error / disabled-until.
        let failing = failingIndexers(indexers: indexers, statuses: indexerStatuses)
        for indexer in failing {
            problems.append(Problem(
                id: indexer.indexerId.map { "indexer:\($0)" } ?? "indexer:\(indexer.name)",
                severity: .error,
                title: indexer.name,
                detail: indexer.detail,
                source: "indexer"
            ))
        }

        // Health checks (Prowlarr returns only non-OK checks).
        for item in health {
            problems.append(Problem(
                id: item.id.map { "health:\($0)" } ?? "health:\(item.source ?? item.message ?? UUID().uuidString)",
                severity: Self.severity(forHealthType: item.type),
                title: (item.message?.isEmpty == false ? item.message : item.source) ?? "Health check",
                detail: item.source,
                source: "health"
            ))
        }

        let enabledCount = indexers.filter { $0.enable ?? true }.count

        let healthState: HealthState = switch problems.worstBadgeSeverity {
        case .error: .error
        case .warning: .warning
        default: .healthy
        }

        return InstanceStatus(
            health: healthState,
            headline: buildHeadline(failingCount: failing.count, enabledCount: enabledCount),
            problems: problems,
            summaryLine: buildSummary(failingCount: failing.count, enabledCount: enabledCount),
            serviceVersion: version
        )
    }

    private func buildHeadline(failingCount: Int, enabledCount: Int) -> [MetricChip] {
        [
            // "Failing" leads with error emphasis when > 0 so the tile reads red at a glance (task §6.2).
            MetricChip(
                label: "Failing",
                value: "\(failingCount)",
                systemImageName: "exclamationmark.triangle",
                emphasis: failingCount > 0 ? .error : .normal
            ),
            MetricChip(label: "Indexers", value: "\(enabledCount)", systemImageName: "magnifyingglass"),
        ]
    }

    private func buildSummary(failingCount: Int, enabledCount: Int) -> String {
        if enabledCount == 0 { return "No indexers configured" }
        if failingCount > 0 { return "\(failingCount) of \(enabledCount) indexers failing" }
        return "All \(enabledCount) indexers healthy"
    }

    // MARK: Failing-indexer derivation

    /// A failing indexer flattened for display: its id (for a stable problem id), name, and a
    /// human-readable reason.
    struct FailingIndexer {
        let indexerId: Int?
        let name: String
        let detail: String
    }

    /// Joins the `indexerstatus` list (authoritative) with each indexer's nested `status` fallback,
    /// keyed by indexer id, keeping only genuinely-failing entries.
    private func failingStatusByIndexer(
        indexers: [ProwlarrIndexer],
        statuses: [ProwlarrIndexerStatus]
    ) -> [Int: ProwlarrIndexerStatus] {
        var byIndexer: [Int: ProwlarrIndexerStatus] = [:]
        for status in statuses where status.isFailing {
            if let indexerId = status.indexerId { byIndexer[indexerId] = status }
        }
        // Fall back to the nested status when indexerstatus didn't cover this indexer.
        for indexer in indexers {
            if let nested = indexer.status, nested.isFailing, byIndexer[indexer.id] == nil {
                byIndexer[indexer.id] = nested
            }
        }
        return byIndexer
    }

    private func failingIndexers(
        indexers: [ProwlarrIndexer],
        statuses: [ProwlarrIndexerStatus]
    ) -> [FailingIndexer] {
        let indexerById = Dictionary(indexers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let statusByIndexer = failingStatusByIndexer(indexers: indexers, statuses: statuses)

        var result: [FailingIndexer] = []
        for (indexerId, status) in statusByIndexer {
            let indexer = indexerById[indexerId]
            // A user-disabled indexer (enable == false) isn't "failing" — it's off on purpose.
            if let indexer, indexer.enable == false { continue }
            result.append(FailingIndexer(
                indexerId: indexerId,
                name: indexer?.name ?? "Indexer #\(indexerId)",
                detail: failureDetail(indexer: indexer, status: status)
            ))
        }

        // A failing status with no join key still counts, but we can only name it generically.
        for status in statuses where status.isFailing && status.indexerId == nil {
            result.append(FailingIndexer(
                indexerId: nil,
                name: "Unknown indexer",
                detail: failureDetail(indexer: nil, status: status)
            ))
        }

        // Stable, deterministic order for the UI and tests.
        return result.sorted { ($0.indexerId ?? .max, $0.name) < ($1.indexerId ?? .max, $1.name) }
    }

    /// The user-facing reason an indexer is failing: prefer its own `message`, then the disabled-until
    /// / most-recent-failure timestamps.
    private func failureDetail(indexer: ProwlarrIndexer?, status: ProwlarrIndexerStatus) -> String {
        let till = disabledUntilText(status.disabledTill)
        if let message = indexer?.message?.message, !message.isEmpty {
            if let till { return "\(message) (\(till))" }
            return message
        }
        if let till { return "Backing off — \(till)" }
        if let recent = status.mostRecentFailure?.trimmingCharacters(in: .whitespacesAndNewlines), !recent.isEmpty {
            return "Most recent failure: \(recent)"
        }
        return "Indexer is currently failing."
    }

    private static func severity(forHealthType type: String?) -> Problem.Severity {
        switch (type ?? "").lowercased() {
        case "error": return .error
        // A "notice" is informational (e.g. update available) — shown in detail but excluded from
        // the fleet badge (spec §6.4). Everything else (incl. "warning") is a warning.
        case "notice": return .cosmetic
        default: return .warning
        }
    }

    /// Formats an ISO-8601 disabled-until timestamp into a short local string; falls back to the raw
    /// value if it isn't parseable (tolerant of format variations across versions).
    private func disabledUntilText(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        let display = DateFormatter()
        display.dateStyle = .medium
        display.timeStyle = .short

        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: value) {
            return "disabled until \(display.string(from: date))"
        }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) {
            return "disabled until \(display.string(from: date))"
        }
        return "disabled until \(value)"
    }

    // MARK: Raw fetches

    /// The API key header applied to every authenticated `/api/v1/*` call (never logged).
    private var authHeaders: [String: String] { ["X-Api-Key": context.credential] }

    private func fetchSystemStatus() async throws(FleetError) -> ProwlarrSystemStatus {
        try await context.fetchJSON(
            ProwlarrSystemStatus.self,
            path: "/api/v1/system/status",
            headers: authHeaders
        )
    }

    private func fetchIndexers() async throws(FleetError) -> [ProwlarrIndexer] {
        try await context.fetchJSON(
            [ProwlarrIndexer].self,
            path: "/api/v1/indexer",
            headers: authHeaders
        )
    }

    private func fetchIndexerStatuses() async throws(FleetError) -> [ProwlarrIndexerStatus] {
        try await context.fetchJSON(
            [ProwlarrIndexerStatus].self,
            path: "/api/v1/indexerstatus",
            headers: authHeaders
        )
    }

    private func fetchHealth() async throws(FleetError) -> [ProwlarrHealthResource] {
        try await context.fetchJSON(
            [ProwlarrHealthResource].self,
            path: "/api/v1/health",
            headers: authHeaders
        )
    }
}

// MARK: - Application sync (spec §6.2)

extension ProwlarrClient: ApplicationSyncListing {
    /// The configured downstream apps and their indexer-sync level, for the detail "Applications"
    /// section. A `disabled` sync level is flagged `.warning` (indexers won't propagate to that app).
    public func fetchApplications() async throws(FleetError) -> [ActivityItem] {
        let apps = try await context.fetchJSON(
            [ProwlarrApplication].self,
            path: "/api/v1/applications",
            headers: authHeaders
        )
        return apps.map { app in
            let disabled = (app.syncLevel ?? "").lowercased() == "disabled"
            return ActivityItem(
                id: "app:\(app.id.map(String.init) ?? app.name ?? UUID().uuidString)",
                title: app.name ?? app.implementationName ?? "Application",
                subtitle: app.implementationName,
                status: Self.syncLevelText(app.syncLevel),
                severity: disabled ? .warning : nil
            )
        }
    }

    static func syncLevelText(_ level: String?) -> String {
        switch (level ?? "").lowercased() {
        case "fullsync": return "Full sync"
        case "addonly": return "Add only"
        case "disabled": return "Sync off"
        default: return level ?? "—"
        }
    }
}
