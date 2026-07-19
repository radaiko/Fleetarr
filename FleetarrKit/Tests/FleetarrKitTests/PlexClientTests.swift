import Foundation
import Testing
@testable import FleetarrKit

@Suite("Plex client")
struct PlexClientTests {
    /// Routes Plex requests to the right fixture by path (`/identity` vs `/status/sessions`).
    private func routingTransport(identity: Data, sessions: Data) -> MockTransport {
        MockTransport { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/identity") {
                return .response(status: 200, data: identity)
            }
            if path.contains("/status/sessions") {
                return .response(status: 200, data: sessions)
            }
            return .response(status: 200, data: sessions)
        }
    }

    // MARK: fetchStatus

    @Test("fetchStatus reports streams as healthy activity with no problems")
    func fetchStatusHealthy() async throws {
        let identity = try Fixture.data("plex_identity")
        let sessions = try Fixture.data("plex_sessions")
        let client = PlexClient(context: Fixture.context(transport: routingTransport(identity: identity, sessions: sessions)))

        let status = try await client.fetchStatus()

        // Streams are activity, not problems (spec §6.5): healthy, empty problems, no badge.
        #expect(status.health == .healthy)
        #expect(status.problems.isEmpty)
        #expect(status.badgeCount == 0)
        #expect(status.serviceVersion == "1.41.3.9314-a0bfb8370")

        // Headline metric is the active session count.
        #expect(status.headline.first { $0.label == "Streams" }?.value == "2")
        // One of the two sessions is transcoding.
        #expect(status.headline.first { $0.label == "Transcode" }?.value == "1")
        #expect(status.summaryLine == "2 active streams (1 transcoding)")
    }

    // MARK: buildStatus (pure)

    @Test("buildStatus maps an empty session list to zero streams, still healthy")
    func buildStatusEmpty() throws {
        let data = try Fixture.data("plex_sessions_empty")
        let sessions = try ServiceContext.decode(PlexSessionsResponse.self, from: data).mediaContainer
        let client = PlexClient(context: Fixture.context(transport: MockTransport(data: data)))

        let status = client.buildStatus(sessions: sessions, identity: nil)

        #expect(status.health == .healthy)
        #expect(status.problems.isEmpty)
        #expect(status.headline.first { $0.label == "Streams" }?.value == "0")
        // No transcode chip when nothing is transcoding.
        #expect(status.headline.contains { $0.label == "Transcode" } == false)
        #expect(status.summaryLine == "No active streams")
        #expect(status.serviceVersion == nil)
    }

    @Test("buildStatus takes the version from /identity when present")
    func buildStatusUsesIdentityVersion() throws {
        let sessionsData = try Fixture.data("plex_sessions")
        let identityData = try Fixture.data("plex_identity")
        let sessions = try ServiceContext.decode(PlexSessionsResponse.self, from: sessionsData).mediaContainer
        let identity = try ServiceContext.decode(PlexIdentityResponse.self, from: identityData).mediaContainer
        let client = PlexClient(context: Fixture.context(transport: MockTransport(data: sessionsData)))

        let status = client.buildStatus(sessions: sessions, identity: identity)

        #expect(status.serviceVersion == "1.41.3.9314-a0bfb8370")
        #expect(status.headline.first { $0.label == "Streams" }?.value == "2")
    }

    // MARK: fetchActivity

    @Test("fetchActivity maps sessions to activity items: transcode vs direct play")
    func fetchActivityMapsSessions() async throws {
        let identity = try Fixture.data("plex_identity")
        let sessions = try Fixture.data("plex_sessions")
        let client = PlexClient(context: Fixture.context(transport: routingTransport(identity: identity, sessions: sessions)))

        let items = try await client.fetchActivity()
        #expect(items.count == 2)

        let transcoding = try #require(items.first)
        #expect(transcoding.id == "182")
        #expect(transcoding.title == "Game of Thrones - The Rains of Castamere")
        #expect(transcoding.subtitle == "radaiko")
        #expect(transcoding.status == "Transcode")
        #expect(transcoding.severity == nil)
        let progress = try #require(transcoding.progress)
        #expect(abs(progress - (1_324_000.0 / 3_180_000.0)) < 0.0001)
        #expect(transcoding.fields.contains { $0.label == "Device" && $0.value == "iPhone" })
        #expect(transcoding.fields.contains { $0.label == "Bandwidth" && $0.value == "4.2 Mbps" })

        let directPlay = items[1]
        #expect(directPlay.title == "Blade Runner 2049")
        #expect(directPlay.status == "Direct Play")
        #expect(directPlay.subtitle == "guest")
    }

    // MARK: testConnection

    @Test("testConnection returns the Plex version from /identity")
    func testConnectionSucceeds() async throws {
        let identity = try Fixture.data("plex_identity")
        let sessions = try Fixture.data("plex_sessions")
        let client = PlexClient(context: Fixture.context(transport: routingTransport(identity: identity, sessions: sessions)))

        let result = await client.testConnection()
        #expect(result == .success(version: "1.41.3.9314-a0bfb8370"))
    }

    @Test("A transport timeout propagates as a reachability failure")
    func timeoutPropagates() async {
        let client = PlexClient(context: Fixture.context(transport: MockTransport(error: .timedOut)))

        let result = await client.testConnection()
        #expect(result == .failure(.timedOut))
        if case let .failure(error) = result {
            #expect(error.isReachabilityFailure)
        }
    }

    @Test("An HTTP 401 maps to .unauthorized")
    func unauthorizedMaps() async {
        let client = PlexClient(context: Fixture.context(
            transport: MockTransport(handler: { _ in .response(status: 401, data: Data()) })
        ))

        let result = await client.testConnection()
        #expect(result == .failure(.unauthorized))
    }

    @Test("The X-Plex-Token and JSON Accept headers are applied per call")
    func appliesAuthHeaders() async throws {
        let identity = try Fixture.data("plex_identity")
        let sessions = try Fixture.data("plex_sessions")
        let transport = routingTransport(identity: identity, sessions: sessions)
        let client = PlexClient(context: Fixture.context(transport: transport, credential: "plex-secret-token"))

        _ = try await client.fetchStatus()

        let sessionRequest = try #require(transport.sentRequests.first { $0.url?.path.contains("/status/sessions") == true })
        #expect(sessionRequest.value(forHTTPHeaderField: "X-Plex-Token") == "plex-secret-token")
        #expect(sessionRequest.value(forHTTPHeaderField: "Accept") == "application/json")
    }
}
