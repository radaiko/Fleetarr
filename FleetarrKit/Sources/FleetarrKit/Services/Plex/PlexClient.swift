import Foundation

/// Plex Media Server integration (spec §6.5). The headline metric is **Streams** — the count of
/// active playback sessions. Streams are *activity*, not *problems*: a reachable Plex server is
/// reported `.healthy` with an empty problem list, and the sessions surface on the detail screen.
///
/// Auth is per-call: every request carries an `X-Plex-Token` header plus `Accept: application/json`
/// (Plex returns XML by default). The base URL is the bare server URL (e.g. `http://host:32400`).
/// The plex.tv PIN OAuth flow that mints the token is a separate auth concern and is intentionally
/// *not* implemented here — this client assumes the token credential is already present.
public struct PlexClient: FleetService {
    public let serviceType: ServiceType = .plex

    private let context: ServiceContext

    public init(context: ServiceContext) {
        self.context = context
    }

    // MARK: FleetService

    public func testConnection() async -> ConnectionTestResult {
        do {
            // `/identity` is unauthenticated (200s without a token), so validate the token with an
            // authenticated call (`/status/sessions`, which 401s on a bad token) and take the
            // version from the best-effort `/identity` probe.
            _ = try await fetchSessionsRaw()
            let version = (try? await fetchIdentityRaw())?.version
            return .success(version: version)
        } catch {
            return .failure(error)
        }
    }

    public func fetchStatus() async throws(FleetError) -> InstanceStatus {
        let sessions = try await fetchSessionsRaw()
        // Version is best-effort: an /identity failure must not blank the tile (spec §9.5).
        let identity = try? await fetchIdentityRaw()
        return buildStatus(sessions: sessions, identity: identity)
    }

    public func fetchActivity() async throws(FleetError) -> [ActivityItem] {
        let sessions = try await fetchSessionsRaw()
        return (sessions.metadata ?? []).map(activityItem(from:))
    }

    // MARK: Status assembly (pure, unit-testable)

    /// Builds the dashboard status from the raw sessions payload. Pure so it can be tested directly
    /// against recorded fixtures without a transport (spec §9.8).
    func buildStatus(sessions: PlexSessions, identity: PlexIdentity?) -> InstanceStatus {
        let items = sessions.metadata ?? []
        let streamCount = sessions.size ?? items.count
        let transcodeCount = items.filter(\.isTranscoding).count

        var headline: [MetricChip] = [
            MetricChip(label: "Streams", value: "\(streamCount)", systemImageName: "play.tv"),
        ]
        if transcodeCount > 0 {
            headline.append(MetricChip(
                label: "Transcode",
                value: "\(transcodeCount)",
                systemImageName: "arrow.triangle.2.circlepath"
            ))
        }

        // Streams are activity, not problems: a reachable Plex server has no problems and is
        // healthy (spec §6.5). Connectivity/auth failures surface via thrown FleetError instead.
        return InstanceStatus(
            health: .healthy,
            headline: headline,
            problems: [],
            summaryLine: buildSummary(streamCount: streamCount, transcodeCount: transcodeCount),
            serviceVersion: identity?.version
        )
    }

    private func buildSummary(streamCount: Int, transcodeCount: Int) -> String {
        guard streamCount > 0 else { return "No active streams" }
        let noun = streamCount == 1 ? "stream" : "streams"
        if transcodeCount > 0 {
            return "\(streamCount) active \(noun) (\(transcodeCount) transcoding)"
        }
        return "\(streamCount) active \(noun)"
    }

    // MARK: Activity mapping

    func activityItem(from session: PlexSession) -> ActivityItem {
        var fields: [ActivityItem.Field] = []
        if let device = nonEmpty(session.player?.device) ?? nonEmpty(session.player?.product) {
            fields.append(.init(label: "Device", value: device))
        }
        if let bandwidth = session.session?.bandwidth {
            fields.append(.init(label: "Bandwidth", value: formatBandwidth(bandwidth)))
        }
        if let state = nonEmpty(session.player?.state) {
            fields.append(.init(label: "State", value: state.capitalized))
        }

        return ActivityItem(
            id: session.sessionKey ?? session.ratingKey ?? UUID().uuidString,
            title: displayTitle(for: session),
            subtitle: nonEmpty(session.user?.title),
            progress: progress(for: session),
            status: session.isTranscoding ? "Transcode" : "Direct Play",
            // A stream is not a problem, so it carries no severity (spec §6.5).
            severity: nil,
            fields: fields
        )
    }

    /// "Show – Episode" for episodes, falling back to whatever single title is present.
    private func displayTitle(for session: PlexSession) -> String {
        let show = nonEmpty(session.grandparentTitle)
        let item = nonEmpty(session.title)
        switch (show, item) {
        case let (show?, item?): return "\(show) - \(item)"
        case let (show?, nil): return show
        case let (nil, item?): return item
        case (nil, nil): return "Unknown"
        }
    }

    /// Playback progress in `0...1` from `viewOffset` / `duration` (both milliseconds).
    private func progress(for session: PlexSession) -> Double? {
        guard let offset = session.viewOffset, let duration = session.duration, duration > 0 else {
            return nil
        }
        return min(max(Double(offset) / Double(duration), 0), 1)
    }

    // MARK: Raw fetches

    /// Auth applied per-call: the Plex token header plus a JSON `Accept` (never logged; spec §4).
    private var authHeaders: [String: String] {
        [
            "X-Plex-Token": context.credential,
            "Accept": "application/json",
        ]
    }

    /// Cheap reachability probe (spec §4). `/identity` is unauthenticated: it confirms the host is
    /// really a Plex server and returns its `machineIdentifier` + `version`.
    private func fetchIdentityRaw() async throws(FleetError) -> PlexIdentity {
        let response = try await context.fetchJSON(
            PlexIdentityResponse.self,
            path: "/identity",
            headers: authHeaders
        )
        return response.mediaContainer
    }

    private func fetchSessionsRaw() async throws(FleetError) -> PlexSessions {
        let response = try await context.fetchJSON(
            PlexSessionsResponse.self,
            path: "/status/sessions",
            headers: authHeaders
        )
        return response.mediaContainer
    }

    // MARK: Helpers

    private func nonEmpty(_ string: String?) -> String? {
        guard let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// `Session.bandwidth` is a kilobits-per-second estimate; present it human-readably.
    private func formatBandwidth(_ kbps: Int) -> String {
        if kbps >= 1000 {
            return String(format: "%.1f Mbps", Double(kbps) / 1000)
        }
        return "\(kbps) kbps"
    }
}
