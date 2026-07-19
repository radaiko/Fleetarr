import Foundation
import Testing
@testable import FleetarrKit

@Suite("Jellyfin client")
struct JellyfinClientTests {
    /// Routes Jellyfin requests to the right fixture by path (/Sessions vs /System/Info).
    private func routingTransport(info: Data, sessions: Data) -> MockTransport {
        MockTransport { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/Sessions") { return .response(status: 200, data: sessions) }
            if path.contains("/System/Info") { return .response(status: 200, data: info) }
            return .response(status: 200, data: info)
        }
    }

    @Test("fetchStatus reports streams as activity and stays healthy with no problems")
    func fetchStatusBuildsStreamsMetric() async throws {
        let info = try Fixture.data("jellyfin_system_info")
        let sessions = try Fixture.data("jellyfin_sessions")
        let client = JellyfinClient(context: Fixture.context(transport: routingTransport(info: info, sessions: sessions)))

        let status = try await client.fetchStatus()

        // Streams are activity, not problems (spec §6.6) — reachable Jellyfin is healthy.
        #expect(status.health == .healthy)
        #expect(status.problems.isEmpty)
        #expect(status.badgeCount == 0)
        #expect(status.serviceVersion == "10.10.7")

        // Two sessions have NowPlayingItem (alice + carol); bob is idle/control-only.
        #expect(status.headline.first { $0.label == "Streams" }?.value == "2")
        // Only alice is transcoding.
        #expect(status.headline.first { $0.label == "Transcodes" }?.value == "1")
        #expect(status.summaryLine == "2 streams (1 transcoding)")
    }

    @Test("buildStatus is pure and counts only sessions with NowPlayingItem")
    func buildStatusIsPure() throws {
        let sessions = try ServiceContext.decode([JellyfinSession].self, from: Fixture.data("jellyfin_sessions"))
        let info = try ServiceContext.decode(JellyfinSystemInfo.self, from: Fixture.data("jellyfin_system_info"))
        let client = JellyfinClient(context: Fixture.context(transport: MockTransport(data: Data())))

        let status = client.buildStatus(info: info, sessions: sessions)

        #expect(status.health == .healthy)
        #expect(status.headline.first { $0.label == "Streams" }?.value == "2")
        #expect(status.serviceVersion == "10.10.7")
    }

    @Test("fetchActivity maps playing sessions to activity items with progress and transcode fields")
    func fetchActivityMapsSessions() async throws {
        let info = try Fixture.data("jellyfin_system_info")
        let sessions = try Fixture.data("jellyfin_sessions")
        let client = JellyfinClient(context: Fixture.context(transport: routingTransport(info: info, sessions: sessions)))

        let items = try await client.fetchActivity()

        // Only the two playing sessions map to items; the idle session is dropped.
        #expect(items.count == 2)

        let matrix = try #require(items.first)
        #expect(matrix.title == "The Matrix")          // movie has no SeriesName, falls back to Name
        #expect(matrix.subtitle == "alice")
        #expect(matrix.status == "Transcode")
        let progress = try #require(matrix.progress)
        #expect(abs(progress - 0.151) < 0.001)          // 12340000000 / 81720000000 ticks
        #expect(matrix.severity == nil)                 // a stream is not a problem
        #expect(matrix.fields.contains { $0.label == "Transcode" && $0.value.contains("VideoCodecNotSupported") })

        let severance = items[1]
        #expect(severance.title == "Severance")         // episode uses SeriesName
        #expect(severance.subtitle == "carol")
        #expect(severance.status == "DirectPlay")
        #expect(severance.progress == 0.25)             // 6900000000 / 27600000000 ticks
    }

    @Test("testConnection returns the server version on success")
    func testConnectionSucceeds() async throws {
        let info = try Fixture.data("jellyfin_system_info")
        let client = JellyfinClient(context: Fixture.context(transport: MockTransport(data: info)))

        let result = await client.testConnection()
        #expect(result == .success(version: "10.10.7"))
    }

    @Test("A bad token (HTTP 401) maps to .unauthorized")
    func unauthorizedIsDetected() async throws {
        let client = JellyfinClient(context: Fixture.context(transport: MockTransport(data: Data(), status: 401)))

        let result = await client.testConnection()
        #expect(result == .failure(.unauthorized))

        await #expect(throws: FleetError.unauthorized) {
            try await client.fetchStatus()
        }
    }

    @Test("A transport timeout propagates as a reachability failure")
    func timeoutPropagates() async {
        let client = JellyfinClient(context: Fixture.context(transport: MockTransport(error: .timedOut)))

        let result = await client.testConnection()
        #expect(result == .failure(.timedOut))
        if case let .failure(error) = result {
            #expect(error.isReachabilityFailure)
        }
    }

    @Test("The Authorization header carries the MediaBrowser token")
    func sendsMediaBrowserAuthHeader() async throws {
        let info = try Fixture.data("jellyfin_system_info")
        let transport = MockTransport(data: info)
        let client = JellyfinClient(context: Fixture.context(transport: transport, credential: "secret-token"))

        _ = await client.testConnection()

        let header = transport.sentRequests.first?.value(forHTTPHeaderField: "Authorization")
        #expect(header == "MediaBrowser Token=\"secret-token\", Client=\"Fleetarr\", Device=\"Fleetarr\", DeviceId=\"Fleetarr\", Version=\"1.0\"")
    }

    @Test("TranscodeReasons decodes from a legacy comma-joined string too")
    func transcodeReasonsTolerantDecoding() throws {
        let json = Data("""
        [
          {
            "Id": "x",
            "UserName": "dave",
            "NowPlayingItem": { "Name": "Legacy", "RunTimeTicks": 100 },
            "PlayState": { "PositionTicks": 50, "PlayMethod": "Transcode" },
            "TranscodingInfo": { "TranscodeReasons": "VideoCodecNotSupported, AudioCodecNotSupported" }
          }
        ]
        """.utf8)

        let sessions = try ServiceContext.decode([JellyfinSession].self, from: json)
        let reasons = try #require(sessions.first?.transcodingInfo?.transcodeReasons)
        #expect(reasons == ["VideoCodecNotSupported", "AudioCodecNotSupported"])
    }
}
