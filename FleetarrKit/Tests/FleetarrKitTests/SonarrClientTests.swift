import Foundation
import Testing
@testable import FleetarrKit

@Suite("Sonarr client")
struct SonarrClientTests {
    /// Routes Sonarr requests to the right fixture by URL path.
    private func routingTransport(
        systemStatus: Data,
        health: Data,
        queue: Data,
        missing: Data
    ) -> MockTransport {
        MockTransport { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/system/status") { return .response(status: 200, data: systemStatus) }
            if path.hasSuffix("/health") { return .response(status: 200, data: health) }
            if path.hasSuffix("/wanted/missing") { return .response(status: 200, data: missing) }
            if path.hasSuffix("/queue") { return .response(status: 200, data: queue) }
            return .response(status: 200, data: Data("[]".utf8))
        }
    }

    private func fullTransport() throws -> MockTransport {
        try routingTransport(
            systemStatus: Fixture.data("sonarr_system_status"),
            health: Fixture.data("sonarr_health"),
            queue: Fixture.data("sonarr_queue"),
            missing: Fixture.data("sonarr_missing")
        )
    }

    @Test("fetchStatus classifies health + queue into problems and worst-of health")
    func fetchStatusBuildsProblems() async throws {
        let client = SonarrClient(context: Fixture.context(transport: try fullTransport()))

        let status = try await client.fetchStatus()

        // Health has 1 error + 1 warning (notice + ok excluded); queue has 1 warning + 1 error.
        #expect(status.health == .error)
        #expect(status.badgeCount == 4)
        #expect(status.serviceVersion == "4.0.10.2544")

        // The `notice` and `ok` health items must NOT become problems.
        let healthProblems = status.problems.filter { $0.source == "health" }
        let queueProblems = status.problems.filter { $0.source == "queue" }
        #expect(healthProblems.count == 2)
        #expect(queueProblems.count == 2)

        // The queue error item carries its errorMessage as the detail.
        #expect(queueProblems.contains {
            $0.severity == .error && $0.detail == "Import failed: not enough disk space on /tv"
        })
    }

    @Test("Headline shows Missing count and Queue count with error emphasis")
    func headlineMetrics() async throws {
        let client = SonarrClient(context: Fixture.context(transport: try fullTransport()))

        let status = try await client.fetchStatus()

        let missing = try #require(status.headline.first { $0.label == "Missing" })
        #expect(missing.value == "42")

        let queue = try #require(status.headline.first { $0.label == "Queue" })
        #expect(queue.value == "3")
        // One queue item has trackedDownloadStatus == error → error emphasis (spec §5).
        #expect(queue.emphasis == .error)
    }

    @Test("buildStatus is pure and reports healthy with no problems")
    func buildStatusHealthy() throws {
        let client = SonarrClient(context: Fixture.context(transport: MockTransport(data: Data("{}".utf8))))
        let system = SonarrSystemStatus(version: "4.0.0.1", appName: "Sonarr", instanceName: "Sonarr", branch: "main")
        let emptyQueue = try ServiceContext.decode(SonarrQueue.self, from: Data(#"{"totalRecords":0,"records":[]}"#.utf8))

        let status = client.buildStatus(systemStatus: system, health: [], queue: emptyQueue, missingCount: 0)

        #expect(status.health == .healthy)
        #expect(status.badgeCount == 0)
        #expect(status.summaryLine == "All caught up")
        #expect(status.headline.first { $0.label == "Queue" }?.emphasis == .normal)
    }

    @Test("The API key is sent as the X-Api-Key header, never in the URL")
    func apiKeyHeaderApplied() async throws {
        let transport = try fullTransport()
        let client = SonarrClient(context: Fixture.context(transport: transport, credential: "secret-key"))

        _ = try await client.fetchStatus()

        let request = try #require(transport.sentRequests.first)
        #expect(request.value(forHTTPHeaderField: "X-Api-Key") == "secret-key")
        #expect(request.url?.query?.contains("secret-key") != true)
    }

    @Test("A missing-count failure does not blank the tile")
    func missingFailureIsTolerated() async throws {
        // Route everything except wanted/missing, which returns a 500.
        let transport = MockTransport { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/system/status") { return .response(status: 200, data: (try? Fixture.data("sonarr_system_status")) ?? Data()) }
            if path.hasSuffix("/health") { return .response(status: 200, data: (try? Fixture.data("sonarr_health")) ?? Data()) }
            if path.hasSuffix("/wanted/missing") { return .response(status: 500, data: Data("{}".utf8)) }
            if path.hasSuffix("/queue") { return .response(status: 200, data: (try? Fixture.data("sonarr_queue")) ?? Data()) }
            return .response(status: 200, data: Data("[]".utf8))
        }
        let client = SonarrClient(context: Fixture.context(transport: transport))

        let status = try await client.fetchStatus()

        // Still renders the tile; the Missing chip degrades to a placeholder.
        #expect(status.health == .error)
        #expect(status.headline.first { $0.label == "Missing" }?.value == "—")
    }

    @Test("A bad API key (HTTP 401) maps to .unauthorized")
    func authErrorIsDetected() async throws {
        let client = SonarrClient(context: Fixture.context(
            transport: MockTransport(data: Data(#"{"error":"Unauthorized"}"#.utf8), status: 401)
        ))

        await #expect(throws: FleetError.unauthorized) {
            try await client.fetchStatus()
        }

        let result = await client.testConnection()
        #expect(result == .failure(.unauthorized))
    }

    @Test("A transport timeout propagates as a reachability failure")
    func timeoutPropagates() async {
        let client = SonarrClient(context: Fixture.context(transport: MockTransport(error: .timedOut)))

        let result = await client.testConnection()
        #expect(result == .failure(.timedOut))
        if case let .failure(error) = result {
            #expect(error.isReachabilityFailure)
        }
    }

    @Test("testConnection returns the Sonarr version on success")
    func testConnectionSucceeds() async throws {
        let client = SonarrClient(context: Fixture.context(
            transport: MockTransport(data: try Fixture.data("sonarr_system_status"))
        ))

        let result = await client.testConnection()
        #expect(result == .success(version: "4.0.10.2544"))
    }

    @Test("fetchActivity maps queue records to activity items with progress")
    func fetchActivityMapsRecords() async throws {
        let client = SonarrClient(context: Fixture.context(
            transport: MockTransport(data: try Fixture.data("sonarr_queue"))
        ))

        let items = try await client.fetchActivity()
        #expect(items.count == 3)

        let first = try #require(items.first)
        #expect(first.title == "Some.Show.S03E07.1080p.WEB.h264-GROUP")
        // (2_000_000_000 - 800_000_000) / 2_000_000_000 == 0.6
        #expect(first.progress == 0.6)
        #expect(first.severity == nil)

        // The failed item is flagged with error severity.
        #expect(items.contains { $0.status == "failed" && $0.severity == .error })
    }
}
