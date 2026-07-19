import Foundation

/// SABnzbd integration (spec §6.4) — the download client the project brief called out by name,
/// so its bar is higher than "show the queue": it classifies items into Error/Warning/Cosmetic.
///
/// Auth is the `apikey` query parameter with `output=json`. Note SABnzbd signals API errors (like
/// a bad key) with HTTP 200 and an `{"status": false, "error": ...}` body, which this handles.
public struct SABnzbdClient: FleetService {
    public let serviceType: ServiceType = .sabnzbd

    private let context: ServiceContext
    /// User-editable cosmetic ignore patterns, added to the classifier defaults (spec §6.4).
    private let cosmeticIgnorePatterns: [String]

    public init(context: ServiceContext, cosmeticIgnorePatterns: [String] = []) {
        self.context = context
        self.cosmeticIgnorePatterns = cosmeticIgnorePatterns
    }

    // MARK: FleetService

    public func testConnection() async -> ConnectionTestResult {
        do {
            let queue = try await fetchQueueRaw(limit: 0)
            return .success(version: queue.version)
        } catch {
            return .failure(error)
        }
    }

    public func fetchStatus() async throws(FleetError) -> InstanceStatus {
        let queue = try await fetchQueueRaw()
        // History is best-effort: a history failure must not blank the tile (spec §9.5).
        let history = try? await fetchHistoryRaw(limit: 30)
        return buildStatus(queue: queue, history: history)
    }

    public func fetchActivity() async throws(FleetError) -> [ActivityItem] {
        let queue = try await fetchQueueRaw()
        return (queue.slots ?? []).map { slot in
            ActivityItem(
                id: slot.nzoId,
                title: slot.filename,
                subtitle: slot.category,
                progress: parseDouble(slot.percentage).map { $0 / 100 },
                status: slot.status,
                severity: classify(slot.status, nil),
                fields: [
                    .init(label: "Size", value: slot.size ?? "—"),
                    .init(label: "Left", value: slot.sizeleft ?? "—"),
                    .init(label: "ETA", value: slot.timeleft ?? "—"),
                ]
            )
        }
    }

    // MARK: Status assembly (pure, unit-testable)

    /// Builds the dashboard status from raw queue + history payloads. Pure so it can be tested
    /// directly against recorded fixtures without a transport (spec §9.8).
    func buildStatus(queue: SABQueue, history: SABHistory?) -> InstanceStatus {
        var problems: [Problem] = []

        for slot in queue.slots ?? [] {
            if let severity = classify(slot.status, nil) {
                problems.append(Problem(
                    id: "queue:\(slot.nzoId)",
                    severity: severity,
                    title: slot.filename,
                    detail: "Queue status: \(slot.status)",
                    source: "queue"
                ))
            }
        }

        for slot in history?.slots ?? [] {
            if let severity = classify(slot.status, slot.failMessage) {
                problems.append(Problem(
                    id: "history:\(slot.nzoId)",
                    severity: severity,
                    title: slot.name,
                    detail: slot.failMessage?.isEmpty == false ? slot.failMessage : "History status: \(slot.status)",
                    source: "history"
                ))
            }
        }

        let isPaused = (queue.paused ?? false) || (queue.status?.lowercased() == "paused")
        if isPaused {
            problems.append(Problem(
                id: "queue:paused",
                severity: .warning,
                title: "Queue paused",
                detail: "SABnzbd is paused; downloads won't progress until resumed.",
                source: "queue"
            ))
        }

        let health: HealthState = switch problems.worstBadgeSeverity {
        case .error: .error
        case .warning: .warning
        default: .healthy
        }

        return InstanceStatus(
            health: health,
            headline: buildHeadline(queue: queue, isPaused: isPaused),
            problems: problems,
            summaryLine: buildSummary(queue: queue, isPaused: isPaused),
            serviceVersion: queue.version
        )
    }

    private func buildHeadline(queue: SABQueue, isPaused: Bool) -> [MetricChip] {
        var chips: [MetricChip] = []
        let kbps = parseDouble(queue.kbpersec) ?? 0
        chips.append(MetricChip(label: "Speed", value: formatSpeed(kbPerSec: kbps), systemImageName: "speedometer"))
        chips.append(MetricChip(label: "Queue", value: "\(queue.slots?.count ?? 0)", systemImageName: "tray.full"))
        if isPaused {
            chips.append(MetricChip(label: "Status", value: "Paused", systemImageName: "pause.circle", emphasis: .warning))
        }
        // An active speed cap (SABnzbd reports `speedlimit` as a percentage of the configured max;
        // empty / 0 / 100 all mean "unlimited"). Surface it so a throttled queue isn't mistaken for
        // a slow one (spec §6.4).
        if let limit = parseDouble(queue.speedlimit), limit > 0, limit < 100 {
            chips.append(MetricChip(label: "Limit", value: "\(Int(limit))%",
                                    systemImageName: "gauge.with.dots.needle.bottom.50percent"))
        }
        if let free = parseDouble(queue.diskspace1) {
            chips.append(MetricChip(label: "Free", value: formatGB(free), systemImageName: "internaldrive"))
        }
        return chips
    }

    private func buildSummary(queue: SABQueue, isPaused: Bool) -> String {
        if isPaused { return "Paused" }
        let kbps = parseDouble(queue.kbpersec) ?? 0
        if kbps > 0 { return "Downloading at \(formatSpeed(kbPerSec: kbps))" }
        let status = queue.status?.isEmpty == false ? queue.status! : "Idle"
        return status
    }

    // MARK: Raw fetches

    private func query(mode: String, extra: [URLQueryItem] = []) -> [URLQueryItem] {
        [
            URLQueryItem(name: "mode", value: mode),
            URLQueryItem(name: "output", value: "json"),
            URLQueryItem(name: "apikey", value: context.credential),
        ] + extra
    }

    private func fetchQueueRaw(limit: Int? = nil) async throws(FleetError) -> SABQueue {
        var extra: [URLQueryItem] = []
        if let limit { extra.append(URLQueryItem(name: "limit", value: String(limit))) }
        let request = try context.makeRequest(path: "/api", query: query(mode: "queue", extra: extra))
        let response = try await context.send(request)
        try Self.checkForSABError(response.data)
        return try ServiceContext.decode(SABQueueResponse.self, from: response.data).queue
    }

    private func fetchHistoryRaw(limit: Int? = nil) async throws(FleetError) -> SABHistory {
        var extra: [URLQueryItem] = []
        if let limit { extra.append(URLQueryItem(name: "limit", value: String(limit))) }
        let request = try context.makeRequest(path: "/api", query: query(mode: "history", extra: extra))
        let response = try await context.send(request)
        try Self.checkForSABError(response.data)
        return try ServiceContext.decode(SABHistoryResponse.self, from: response.data).history
    }

    /// Detects SABnzbd's "HTTP 200 + error body" failures and maps them to `FleetError`.
    static func checkForSABError(_ data: Data) throws(FleetError) {
        guard let err = try? JSONDecoder().decode(SABErrorResponse.self, from: data),
              err.status == false || err.error != nil
        else { return }
        let message = (err.error ?? "").lowercased()
        if message.contains("api key") || message.contains("apikey")
            || message.contains("unauthorized") || message.contains("not logged in") {
            throw FleetError.unauthorized
        }
        throw FleetError.transport(err.error ?? "SABnzbd API error")
    }

    // MARK: Helpers

    private func classify(_ status: String, _ failMessage: String?) -> Problem.Severity? {
        SABnzbdSeverityClassifier.classify(
            status: status,
            failMessage: failMessage,
            ignorePatterns: cosmeticIgnorePatterns
        )
    }

    private func parseDouble(_ string: String?) -> Double? {
        guard let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return Double(trimmed)
    }

    private func formatSpeed(kbPerSec: Double) -> String {
        if kbPerSec <= 0 { return "0 KB/s" }
        if kbPerSec >= 1024 { return String(format: "%.1f MB/s", kbPerSec / 1024) }
        return String(format: "%.0f KB/s", kbPerSec)
    }

    private func formatGB(_ gigabytes: Double) -> String {
        if gigabytes >= 1024 { return String(format: "%.1f TB", gigabytes / 1024) }
        return String(format: "%.0f GB", gigabytes)
    }
}

// MARK: - Write actions (spec §6.4)

extension SABnzbdClient: QueueItemRemoving, DownloadControlling {
    public func removeQueueItem(id: String, blocklist: Bool) async throws(FleetError) {
        // SABnzbd has no per-item blocklist, so `blocklist` is ignored. `del_files=1` also removes
        // the partial download from disk.
        try await performCommand(query(mode: "queue", extra: [
            URLQueryItem(name: "name", value: "delete"),
            URLQueryItem(name: "value", value: id),
            URLQueryItem(name: "del_files", value: "1"),
        ]))
    }

    public func setQueuePaused(_ paused: Bool) async throws(FleetError) {
        try await performCommand(query(mode: paused ? "pause" : "resume"))
    }

    public func setItemPaused(_ paused: Bool, id: String) async throws(FleetError) {
        try await performCommand(query(mode: "queue", extra: [
            URLQueryItem(name: "name", value: paused ? "pause" : "resume"),
            URLQueryItem(name: "value", value: id),
        ]))
    }

    public func retryFailedItem(id: String) async throws(FleetError) {
        try await performCommand(query(mode: "retry", extra: [
            URLQueryItem(name: "value", value: id),
        ]))
    }

    private func performCommand(_ items: [URLQueryItem]) async throws(FleetError) {
        let request = try context.makeRequest(path: "/api", query: items)
        let response = try await context.send(request)
        try Self.checkForSABError(response.data)
    }
}

// MARK: - History listing (spec §6.1, §6.4)

extension SABnzbdClient: HistoryListing {
    /// Recent completed/failed downloads for the detail screen's secondary history list (spec §6.4).
    ///
    /// Reuses the existing `fetchHistoryRaw` (which already runs `checkForSABError` on the HTTP-200
    /// error body) and the shared severity classifier, then surfaces genuine failures first while
    /// keeping the server's order for everything else.
    public func fetchRecentHistory() async throws(FleetError) -> [ActivityItem] {
        let history = try await fetchHistoryRaw(limit: 30)
        let items = (history.slots ?? []).map { slot -> ActivityItem in
            var fields: [ActivityItem.Field] = [
                .init(label: "Size", value: slot.size ?? "—"),
            ]
            if let reason = slot.failMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
               !reason.isEmpty {
                fields.append(.init(label: "Failed reason", value: reason))
            }
            return ActivityItem(
                id: slot.nzoId,
                title: slot.name,
                subtitle: slot.category,
                status: slot.status,
                severity: classify(slot.status, slot.failMessage),
                fields: fields
            )
        }
        // Surface genuine failures (.error) first; cosmetic/healthy rows keep server order. Both
        // filters are stable, so relative order within each group is preserved.
        let failures = items.filter { $0.severity == .error }
        let rest = items.filter { $0.severity != .error }
        return failures + rest
    }
}
