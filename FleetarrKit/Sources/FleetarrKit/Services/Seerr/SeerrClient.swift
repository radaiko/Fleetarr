import Foundation

/// Seerr integration (unified Overseerr/Jellyseerr; spec §6.3) — a request-management dashboard.
///
/// Auth is the admin API key sent as an `X-Api-Key` header on every call (no `Bearer` prefix),
/// which also authorizes listing *all* requests and bypasses CSRF. The credential is applied
/// per-call and is **never** logged.
///
/// Pending requests are treated as *activity*, not problems: a healthy, reachable Seerr with a
/// backlog of pending approvals is still `.healthy`, so `problems` stays empty (spec §6.3). The
/// pending count is surfaced as the headline metric with warning emphasis when non-zero.
public struct SeerrClient: FleetService {
    public let serviceType: ServiceType = .seerr

    private let context: ServiceContext

    public init(context: ServiceContext) {
        self.context = context
    }

    /// The Seerr API is rooted at `/api/v1`, joined onto any reverse-proxy path prefix.
    private static let apiRoot = "/api/v1"

    /// Auth header applied to every request. Seerr uses a bare API key (no `Bearer`).
    private var authHeaders: [String: String] {
        ["X-Api-Key": context.credential]
    }

    // MARK: FleetService

    public func testConnection() async -> ConnectionTestResult {
        do {
            // `/status` is unauthenticated and returns 200 even with a wrong/missing key, so it
            // can't validate the credential. Probe an authenticated endpoint (`/request/count`,
            // which 401/403s on a bad key) and take the version from the best-effort `/status`.
            _ = try await fetchRequestCount()
            let version = (try? await fetchSystemStatus())?.version
            return .success(version: version)
        } catch {
            return .failure(error)
        }
    }

    public func fetchStatus() async throws(FleetError) -> InstanceStatus {
        let count = try await fetchRequestCount()
        // The version comes from the unauthenticated /status probe; a failure there must not blank
        // the tile (spec §9.5), so it is best-effort.
        let status = try? await fetchSystemStatus()
        return buildStatus(count: count, status: status)
    }

    public func fetchActivity() async throws(FleetError) -> [ActivityItem] {
        let page = try await fetchPendingRequests(take: 20)
        return (page.results ?? []).map { request in
            ActivityItem(
                id: String(request.id),
                title: "Request #\(request.id)",
                subtitle: request.requestedBy?.resolvedDisplayName,
                progress: nil,
                status: Self.statusText(request.status),
                severity: Self.severity(for: request.status),
                fields: [
                    .init(label: "Type", value: Self.typeLabel(request.type ?? request.media?.mediaType)),
                    .init(label: "TMDB", value: request.media?.tmdbId.map(String.init) ?? "—"),
                    .init(label: "Requested", value: Self.formatDate(request.createdAt)),
                ]
            )
        }
    }

    // MARK: Status assembly (pure, unit-testable)

    /// Builds the dashboard status from the request-count payload (+ optional version). Pure so it
    /// can be tested directly against recorded fixtures without a transport (spec §9.8).
    ///
    /// Pending requests are activity, not problems, so `problems` is empty and — since a reachable
    /// Seerr is always `.healthy` here — the health state is fixed at `.healthy`.
    func buildStatus(count: SeerrRequestCount, status: SeerrStatus?) -> InstanceStatus {
        let pending = count.pending ?? 0

        return InstanceStatus(
            health: .healthy,
            headline: buildHeadline(count: count, pending: pending),
            problems: [],
            summaryLine: buildSummary(pending: pending),
            serviceVersion: status?.version
        )
    }

    private func buildHeadline(count: SeerrRequestCount, pending: Int) -> [MetricChip] {
        var chips: [MetricChip] = [
            MetricChip(
                label: "Pending",
                value: "\(pending)",
                systemImageName: "tray.and.arrow.down",
                emphasis: pending > 0 ? .warning : .normal
            )
        ]
        if let processing = count.processing {
            chips.append(MetricChip(label: "Processing", value: "\(processing)", systemImageName: "arrow.triangle.2.circlepath"))
        }
        if let available = count.available {
            chips.append(MetricChip(label: "Available", value: "\(available)", systemImageName: "checkmark.circle"))
        }
        return chips
    }

    private func buildSummary(pending: Int) -> String {
        switch pending {
        case 0: return "No pending requests"
        case 1: return "1 pending request"
        default: return "\(pending) pending requests"
        }
    }

    // MARK: Raw fetches

    private func fetchSystemStatus() async throws(FleetError) -> SeerrStatus {
        try await context.fetchJSON(
            SeerrStatus.self,
            path: Self.apiRoot + "/status",
            headers: authHeaders
        )
    }

    private func fetchRequestCount() async throws(FleetError) -> SeerrRequestCount {
        try await context.fetchJSON(
            SeerrRequestCount.self,
            path: Self.apiRoot + "/request/count",
            headers: authHeaders
        )
    }

    private func fetchPendingRequests(take: Int) async throws(FleetError) -> SeerrRequestPage {
        try await context.fetchJSON(
            SeerrRequestPage.self,
            path: Self.apiRoot + "/request",
            query: [
                URLQueryItem(name: "take", value: String(take)),
                URLQueryItem(name: "filter", value: "pending"),
                URLQueryItem(name: "sort", value: "added"),
            ],
            headers: authHeaders
        )
    }

    // MARK: Helpers (pure, static — exercised directly by tests)

    /// Maps a `RequestStatus` code to user-facing text.
    static func statusText(_ code: Int?) -> String {
        switch code {
        case 1: return "Pending"
        case 2: return "Approved"
        case 3: return "Declined"
        case 4: return "Failed"
        case 5: return "Completed"
        default: return "Unknown"
        }
    }

    /// Only a failed request represents a problem in an activity list; everything else is a
    /// healthy in-progress item (`nil` severity).
    static func severity(for code: Int?) -> Problem.Severity? {
        code == 4 ? .warning : nil
    }

    /// Normalizes the `"movie"`/`"tv"` marker into a display label.
    static func typeLabel(_ raw: String?) -> String {
        switch raw?.lowercased() {
        case "movie": return "Movie"
        case "tv": return "TV"
        case .some(let other) where !other.isEmpty: return other.capitalized
        default: return "—"
        }
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
