import Foundation

/// Jellyfin integration (spec §6.6) — a media server whose dashboard headline is the number of
/// active streams. Streams are *activity*, not problems: a healthy, reachable Jellyfin reports no
/// problems and the tile stays `.healthy`; transcodes are surfaced for context, not as warnings.
///
/// Auth is the `Authorization: MediaBrowser Token="<credential>"` header, applied per call (the
/// bare server URL is the base — Jellyfin has no `/api/vN` version prefix). The credential is
/// never logged. JSON keys are PascalCase, so decoding uses explicit CodingKeys, not key
/// conversion.
public struct JellyfinClient: FleetService {
    public let serviceType: ServiceType = .jellyfin

    private let context: ServiceContext

    public init(context: ServiceContext) {
        self.context = context
    }

    // MARK: FleetService

    public func testConnection() async -> ConnectionTestResult {
        do {
            let info = try await fetchSystemInfo()
            return .success(version: info.version)
        } catch {
            return .failure(error)
        }
    }

    public func fetchStatus() async throws(FleetError) -> InstanceStatus {
        // /Sessions is the reachability gate (it needs the token, so a bad key surfaces here).
        let sessions = try await fetchSessions()
        // Server info is best-effort: a 403 (non-admin key) on /System/Info must not blank the
        // tile — we just lose the version string (spec §9.5).
        let info = try? await fetchSystemInfo()
        return buildStatus(info: info, sessions: sessions)
    }

    public func fetchActivity() async throws(FleetError) -> [ActivityItem] {
        let sessions = try await fetchSessions()
        return sessions.compactMap(activityItem(for:))
    }

    // MARK: Status assembly (pure, unit-testable)

    /// Builds the dashboard status from a decoded server-info + sessions payload. Pure so it can be
    /// tested directly against recorded fixtures without a transport (spec §9.8).
    func buildStatus(info: JellyfinSystemInfo?, sessions: [JellyfinSession]) -> InstanceStatus {
        let playing = sessions.filter { $0.nowPlayingItem != nil }
        let transcodeCount = playing.filter { isTranscoding($0) }.count

        // Streams are activity, not problems (spec §6.6): reachable Jellyfin is healthy with no
        // problems, so the fleet badge never counts a stream.
        return InstanceStatus(
            health: .healthy,
            headline: buildHeadline(streamCount: playing.count, transcodeCount: transcodeCount),
            problems: [],
            summaryLine: buildSummary(streamCount: playing.count, transcodeCount: transcodeCount),
            serviceVersion: info?.version
        )
    }

    private func buildHeadline(streamCount: Int, transcodeCount: Int) -> [MetricChip] {
        var chips: [MetricChip] = [
            MetricChip(label: "Streams", value: "\(streamCount)", systemImageName: "play.tv")
        ]
        if transcodeCount > 0 {
            chips.append(MetricChip(
                label: "Transcodes",
                value: "\(transcodeCount)",
                systemImageName: "arrow.triangle.2.circlepath"
            ))
        }
        return chips
    }

    private func buildSummary(streamCount: Int, transcodeCount: Int) -> String {
        if streamCount == 0 { return "No active streams" }
        let base = streamCount == 1 ? "1 stream" : "\(streamCount) streams"
        if transcodeCount > 0 { return "\(base) (\(transcodeCount) transcoding)" }
        return base
    }

    // MARK: Activity mapping

    private func activityItem(for session: JellyfinSession) -> ActivityItem? {
        guard let item = session.nowPlayingItem else { return nil }

        var fields: [ActivityItem.Field] = []
        if let device = session.deviceName ?? session.client {
            fields.append(.init(label: "Device", value: device))
        }
        if let reasons = session.transcodingInfo?.transcodeReasons, !reasons.isEmpty {
            fields.append(.init(label: "Transcode", value: reasons.joined(separator: ", ")))
        }

        return ActivityItem(
            id: session.id ?? UUID().uuidString,
            title: item.seriesName ?? item.name ?? "Unknown",
            subtitle: session.userName,
            progress: progress(position: session.playState?.positionTicks, runtime: item.runTimeTicks),
            status: session.playState?.playMethod,
            severity: nil,
            fields: fields
        )
    }

    // MARK: Raw fetches

    /// The Jellyfin auth header. The credential is embedded here and never logged (spec §4). Only
    /// `Token` is required; the client-identity params just label the session in the dashboard.
    private var authHeaders: [String: String] {
        [
            "Authorization": "MediaBrowser Token=\"\(context.credential)\", Client=\"Fleetarr\", Device=\"Fleetarr\", DeviceId=\"Fleetarr\", Version=\"1.0\"",
        ]
    }

    private func fetchSystemInfo() async throws(FleetError) -> JellyfinSystemInfo {
        try await context.fetchJSON(JellyfinSystemInfo.self, path: "/System/Info", headers: authHeaders)
    }

    private func fetchSessions() async throws(FleetError) -> [JellyfinSession] {
        try await context.fetchJSON([JellyfinSession].self, path: "/Sessions", headers: authHeaders)
    }

    // MARK: Helpers

    private func isTranscoding(_ session: JellyfinSession) -> Bool {
        session.playState?.playMethod?.lowercased() == "transcode"
    }

    /// Playback progress in `0...1` from .NET ticks, or nil when the runtime is unknown/zero.
    private func progress(position: Int64?, runtime: Int64?) -> Double? {
        guard let position, let runtime, runtime > 0 else { return nil }
        return min(max(Double(position) / Double(runtime), 0), 1)
    }
}
