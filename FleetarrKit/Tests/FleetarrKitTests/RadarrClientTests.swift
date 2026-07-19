import Foundation
import Testing
@testable import FleetarrKit

@Suite("Radarr client")
struct RadarrClientTests {
    /// Routes Radarr requests to the right fixture based on the request path.
    private func routingTransport(system: Data, health: Data, queue: Data, missing: Data) -> MockTransport {
        MockTransport { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/system/status") { return .response(status: 200, data: system) }
            if path.hasSuffix("/health") { return .response(status: 200, data: health) }
            if path.hasSuffix("/wanted/missing") { return .response(status: 200, data: missing) }
            if path.hasSuffix("/queue") { return .response(status: 200, data: queue) }
            return .response(status: 200, data: system)
        }
    }

    // MARK: buildStatus (pure)

    @Test("buildStatus maps health + queue into problems, health state, and headline")
    func buildStatusFromFixtures() throws {
        let system = try ServiceContext.decode(RadarrSystemStatus.self, from: Fixture.data("radarr_system_status"))
        let health = try ServiceContext.decode([RadarrHealthResource].self, from: Fixture.data("radarr_health"))
        let queue = try ServiceContext.decode(RadarrQueueResponse.self, from: Fixture.data("radarr_queue"))
        let missing = try ServiceContext.decode(RadarrMissingResponse.self, from: Fixture.data("radarr_missing"))

        let client = RadarrClient(context: Fixture.context(transport: MockTransport(data: Data())))
        let status = client.buildStatus(
            system: system,
            health: health,
            queue: queue.records ?? [],
            missingCount: missing.totalRecords
        )

        // health has 1 error → overall error state.
        #expect(status.health == .error)
        // Badge counts: health warning + health error + queue warning = 3. The health notice is
        // cosmetic and excluded; the healthy "ok" queue item contributes no problem.
        #expect(status.badgeCount == 3)
        #expect(status.problems.count == 4)
        #expect(status.serviceVersion == "5.14.0.9383")

        let cosmeticCount = status.problems.filter { $0.severity == .cosmetic }.count
        #expect(cosmeticCount == 1)

        // Headline: Missing (totalRecords) + Queue (record count) with warning emphasis on the queue.
        #expect(status.headline.first { $0.label == "Missing" }?.value == "7")
        let queueChip = try #require(status.headline.first { $0.label == "Queue" })
        #expect(queueChip.value == "2")
        #expect(queueChip.emphasis == .warning)
    }

    // MARK: fetchStatus (full transport flow)

    @Test("fetchStatus fans out to system/health/queue/missing and builds the tile")
    func fetchStatusFullFlow() async throws {
        let client = RadarrClient(context: Fixture.context(transport: routingTransport(
            system: try Fixture.data("radarr_system_status"),
            health: try Fixture.data("radarr_health"),
            queue: try Fixture.data("radarr_queue"),
            missing: try Fixture.data("radarr_missing")
        )))

        let status = try await client.fetchStatus()
        #expect(status.health == .error)
        #expect(status.badgeCount == 3)
        #expect(status.headline.first { $0.label == "Missing" }?.value == "7")
        #expect(status.headline.first { $0.label == "Queue" }?.value == "2")
    }

    @Test("A missing/queue/health failure does not blank the tile — only system/status is required")
    func auxiliaryFailureDegradesGracefully() async throws {
        // Every non-status endpoint 500s; system/status still succeeds.
        let system = try Fixture.data("radarr_system_status")
        let transport = MockTransport { request in
            if request.url?.path.hasSuffix("/system/status") == true {
                return .response(status: 200, data: system)
            }
            return .response(status: 500, data: Data())
        }
        let client = RadarrClient(context: Fixture.context(transport: transport))

        let status = try await client.fetchStatus()
        #expect(status.health == .healthy)
        #expect(status.serviceVersion == "5.14.0.9383")
        #expect(status.headline.first { $0.label == "Missing" }?.value == "0")
        #expect(status.headline.first { $0.label == "Queue" }?.value == "0")
    }

    // MARK: testConnection

    @Test("testConnection returns the Radarr version on success and sends the X-Api-Key header")
    func testConnectionSucceeds() async throws {
        let transport = MockTransport(data: try Fixture.data("radarr_system_status"))
        let client = RadarrClient(context: Fixture.context(transport: transport))

        let result = await client.testConnection()
        #expect(result == .success(version: "5.14.0.9383"))
        // The credential is applied as the X-Api-Key header on every call (never as a logged param).
        #expect(transport.sentRequests.first?.value(forHTTPHeaderField: "X-Api-Key") == "test-key")
    }

    @Test("A 401 from system/status maps to .unauthorized")
    func authErrorIsDetected() async throws {
        let body = Data(#"{"message":"Unauthorized"}"#.utf8)
        let client = RadarrClient(context: Fixture.context(transport: MockTransport(data: body, status: 401)))

        await #expect(throws: FleetError.unauthorized) {
            try await client.fetchStatus()
        }

        let result = await client.testConnection()
        #expect(result == .failure(.unauthorized))
    }

    @Test("A transport timeout propagates as a reachability failure")
    func timeoutPropagates() async {
        let client = RadarrClient(context: Fixture.context(transport: MockTransport(error: .timedOut)))

        let result = await client.testConnection()
        #expect(result == .failure(.timedOut))
        if case let .failure(error) = result {
            #expect(error.isReachabilityFailure)
        }
    }

    // MARK: fetchActivity

    @Test("fetchActivity maps queue records to activity items with progress and severity")
    func fetchActivityMapsRecords() async throws {
        let client = RadarrClient(context: Fixture.context(transport: MockTransport(data: try Fixture.data("radarr_queue"))))

        let items = try await client.fetchActivity()
        #expect(items.count == 2)

        let first = try #require(items.first)
        #expect(first.title == "Dune: Part Two")
        #expect(first.progress == 0.75)
        #expect(first.severity == nil)

        // The second record is trackedDownloadStatus=warning.
        #expect(items[1].severity == .warning)
    }
}
