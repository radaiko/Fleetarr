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

// MARK: - Detail-screen secondary lists (spec §6.1)
//
// Read-only lists the Radarr detail screen renders below the primary queue activity: the calendar
// (Upcoming), recent history (grabs / imports / failures), and wanted-but-missing movies. Each maps
// to the generic `ActivityItem`. Decoding stays tolerant (all model fields optional) and results are
// capped at `listingPageSize` so a huge library can't flood the UI.

extension RadarrClient: UpcomingListing {
    /// Movies with a release date inside the next `days`-day window, from `GET /api/v3/calendar`.
    /// `title` is the movie name (+ year), `subtitle` the nearest known release date, and `status`
    /// is "Available" when the file already exists on disk, otherwise "Upcoming".
    public func fetchUpcoming(days: Int) async throws(FleetError) -> [ActivityItem] {
        let now = Date()
        let end = now.addingTimeInterval(TimeInterval(max(days, 1)) * 86_400)
        let iso = ISO8601DateFormatter()
        let movies = try await context.fetchJSON(
            [RadarrListMovie].self,
            path: "/api/v3/calendar",
            query: [
                URLQueryItem(name: "start", value: iso.string(from: now)),
                URLQueryItem(name: "end", value: iso.string(from: end)),
                URLQueryItem(name: "unmonitored", value: "false"),
            ],
            headers: authHeaders
        )
        let today = String(iso.string(from: now).prefix(10))
        return movies.prefix(Self.listingPageSize).enumerated().map { index, movie in
            // Prefer the next release ON OR AFTER today: a movie can be pulled into the window by a
            // future digital release while still carrying a past theatrical date, and labelling that
            // past date "Upcoming" is misleading.
            let nearest = Self.nextRelease(movie, onOrAfter: today)
            let hasFile = movie.hasFile ?? false
            var fields = Self.releaseCandidates(movie).map {
                ActivityItem.Field(label: $0.label, value: Self.formatDate($0.raw))
            }
            fields.append(.init(label: "Monitored", value: (movie.monitored ?? false) ? "Yes" : "No"))
            return ActivityItem(
                id: Self.listingID(movie, fallbackIndex: index, prefix: "calendar"),
                title: Self.movieTitle(movie),
                subtitle: nearest.map { "\($0.label) · \(Self.formatDate($0.raw))" } ?? "No release date",
                status: hasFile ? "Available" : "Upcoming",
                severity: nil,
                fields: Array(fields.prefix(4))
            )
        }
    }
}

extension RadarrClient: HistoryListing {
    /// The most recent grabs / imports / failures from `GET /api/v3/history` (newest first). A
    /// `downloadFailed` / `importFailed` event carries `.error` severity so the UI can surface it.
    public func fetchRecentHistory() async throws(FleetError) -> [ActivityItem] {
        let response = try await context.fetchJSON(
            RadarrHistoryResponse.self,
            path: "/api/v3/history",
            query: [
                URLQueryItem(name: "pageSize", value: String(Self.listingPageSize)),
                URLQueryItem(name: "sortKey", value: "date"),
                URLQueryItem(name: "sortDirection", value: "descending"),
                URLQueryItem(name: "includeMovie", value: "true"),
            ],
            headers: authHeaders
        )
        return (response.records ?? []).enumerated().map { index, record in
            let title = record.movie.map(Self.movieTitle) ?? record.sourceTitle ?? "Unknown"
            var fields: [ActivityItem.Field] = []
            if let quality = record.quality?.quality?.name, !quality.isEmpty {
                fields.append(.init(label: "Quality", value: quality))
            }
            if let indexer = record.data?.indexer, !indexer.isEmpty {
                fields.append(.init(label: "Indexer", value: indexer))
            } else if let client = record.data?.downloadClient, !client.isEmpty {
                fields.append(.init(label: "Client", value: client))
            }
            if let source = record.sourceTitle, !source.isEmpty, source != title {
                fields.append(.init(label: "Release", value: source))
            }
            return ActivityItem(
                id: record.id.map { "history:\($0)" } ?? "history:\(index)",
                title: title,
                subtitle: Self.formatDate(record.date),
                status: Self.historyEventLabel(record.eventType),
                severity: Self.historyIsFailure(record.eventType) ? .error : nil,
                fields: Array(fields.prefix(4))
            )
        }
    }
}

extension RadarrClient: MissingListing {
    /// Monitored movies with no file yet, from `GET /api/v3/wanted/missing`. `title` is the movie
    /// (+ year), `subtitle` the nearest release date, and the fields flag whether it's monitored and
    /// available to search. No severity — a wanted movie is a normal state, not a problem.
    public func fetchMissing() async throws(FleetError) -> [ActivityItem] {
        let response = try await context.fetchJSON(
            RadarrMissingListResponse.self,
            path: "/api/v3/wanted/missing",
            query: [
                URLQueryItem(name: "pageSize", value: String(Self.listingPageSize)),
                URLQueryItem(name: "sortKey", value: "movieMetadata.sortTitle"),
                URLQueryItem(name: "sortDirection", value: "ascending"),
                URLQueryItem(name: "monitored", value: "true"),
            ],
            headers: authHeaders
        )
        return (response.records ?? []).enumerated().map { index, movie in
            let nearest = Self.nearestRelease(movie)
            let available = movie.isAvailable ?? false
            return ActivityItem(
                id: Self.listingID(movie, fallbackIndex: index, prefix: "missing"),
                title: Self.movieTitle(movie),
                subtitle: nearest.map { "\($0.label) · \(Self.formatDate($0.raw))" } ?? "No release date",
                status: available ? "Wanted" : "Not yet available",
                severity: nil,
                fields: [
                    .init(label: "Monitored", value: (movie.monitored ?? false) ? "Yes" : "No"),
                    .init(label: "Available", value: available ? "Yes" : "No"),
                ]
            )
        }
    }
}

// MARK: - Listing helpers (shared by the three lists above)

private extension RadarrClient {
    /// Cap for each secondary list so a large library can't flood the detail screen (spec §6.1).
    static var listingPageSize: Int { 30 }

    /// "Title (Year)" when a year is present, otherwise just the title.
    static func movieTitle(_ movie: RadarrListMovie) -> String {
        let title = movie.title ?? "Unknown"
        if let year = movie.year, year > 0 { return "\(title) (\(year))" }
        return title
    }

    /// A stable id for a listing row: prefer the movie's own id, else a per-list positional key.
    static func listingID(_ movie: RadarrListMovie, fallbackIndex: Int, prefix: String) -> String {
        if let id = movie.id { return "\(prefix):\(id)" }
        return "\(prefix):\(fallbackIndex)"
    }

    /// The present release dates on a movie, labelled and in a stable order.
    static func releaseCandidates(_ movie: RadarrListMovie) -> [(label: String, raw: String)] {
        var out: [(label: String, raw: String)] = []
        if let value = movie.inCinemas, !value.isEmpty { out.append(("In cinemas", value)) }
        if let value = movie.digitalRelease, !value.isEmpty { out.append(("Digital", value)) }
        if let value = movie.physicalRelease, !value.isEmpty { out.append(("Physical", value)) }
        if out.isEmpty, let value = movie.releaseDate, !value.isEmpty { out.append(("Release", value)) }
        return out
    }

    /// The chronologically earliest known release date. ISO-8601 timestamps in the same format
    /// sort chronologically as plain strings, so no `Date` parsing (or formatter) is needed here;
    /// unparseable/short values simply sort as written, which is deterministic and good enough.
    static func nearestRelease(_ movie: RadarrListMovie) -> (label: String, raw: String)? {
        releaseCandidates(movie).min { $0.raw < $1.raw }
    }

    /// The earliest release date on or after `referenceDay` (yyyy-MM-dd), falling back to the
    /// earliest known date when none are in the future. Used for the calendar/upcoming context so a
    /// past theatrical date isn't presented as the upcoming release.
    static func nextRelease(_ movie: RadarrListMovie, onOrAfter referenceDay: String) -> (label: String, raw: String)? {
        let candidates = releaseCandidates(movie)
        let upcoming = candidates
            .filter { String($0.raw.prefix(10)) >= referenceDay }
            .min { $0.raw < $1.raw }
        return upcoming ?? candidates.min { $0.raw < $1.raw }
    }

    /// A short, human label for a MovieHistoryEventType.
    static func historyEventLabel(_ eventType: String?) -> String {
        switch eventType?.lowercased() {
        case "grabbed": return "Grabbed"
        case "downloadfolderimported", "moviefolderimported": return "Imported"
        case "downloadfailed": return "Download failed"
        case "importfailed": return "Import failed"
        case "moviefiledeleted": return "File deleted"
        case "moviefilerenamed": return "Renamed"
        case "downloadignored": return "Ignored"
        case let other?: return other.capitalized
        case nil: return "Event"
        }
    }

    /// Whether a history event represents a failure (→ `.error` severity).
    static func historyIsFailure(_ eventType: String?) -> Bool {
        (eventType?.lowercased() ?? "").contains("failed")
    }

    /// Renders an ISO-8601 timestamp as its calendar date, falling back to the raw value. Kept
    /// simple and deterministic (no locale/timezone drift) for the compact detail row.
    static func formatDate(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "—" }
        if let tIndex = raw.firstIndex(of: "T") {
            return String(raw[raw.startIndex..<tIndex])
        }
        return raw
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

extension RadarrClient: ManualSearching {
    /// Missing/Calendar ids are `"prefix:movieId"`; kick off a `MoviesSearch` command for that movie
    /// (spec §6.1). Ids in the composite fallback form (no movie id) can't be searched.
    public func searchForItem(id: String) async throws(FleetError) {
        guard let movieId = Self.wantedNumericID(id) else {
            throw FleetError.transport("This item can't be searched.")
        }
        let body = try? JSONSerialization.data(withJSONObject: ["name": "MoviesSearch", "movieIds": [movieId]])
        var headers = authHeaders
        headers["Content-Type"] = "application/json"
        let request = try context.makeRequest(path: "/api/v3/command", method: "POST", headers: headers, body: body)
        _ = try await context.send(request)
    }

    /// The numeric id from a two-part `"prefix:id"` activity id (nil for the composite fallback form).
    static func wantedNumericID(_ id: String) -> Int? {
        let parts = id.split(separator: ":")
        guard parts.count == 2 else { return nil }
        return Int(parts[1])
    }
}
