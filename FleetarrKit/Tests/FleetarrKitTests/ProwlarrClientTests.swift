import Foundation
import Testing
@testable import FleetarrKit

@Suite("Prowlarr client")
struct ProwlarrClientTests {
    /// Routes Prowlarr's `/api/v1/*` requests to the right fixture by path suffix.
    private func routingTransport(
        indexers: Data,
        statuses: Data,
        health: Data,
        system: Data
    ) -> MockTransport {
        MockTransport { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/indexerstatus") { return .response(status: 200, data: statuses) }
            if path.hasSuffix("/indexer") { return .response(status: 200, data: indexers) }
            if path.hasSuffix("/health") { return .response(status: 200, data: health) }
            if path.hasSuffix("/system/status") { return .response(status: 200, data: system) }
            return .response(status: 200, data: indexers)
        }
    }

    @Test("fetchStatus counts failing indexers and surfaces each with its error, plus health items")
    func fetchStatusBuildsProblems() async throws {
        let indexers = try Fixture.data("prowlarr_indexer")
        let statuses = try Fixture.data("prowlarr_indexerstatus")
        let health = try Fixture.data("prowlarr_health")
        let system = try Fixture.data("prowlarr_system_status")
        let client = ProwlarrClient(context: Fixture.context(
            transport: routingTransport(indexers: indexers, statuses: statuses, health: health, system: system)
        ))

        let status = try await client.fetchStatus()

        // One indexer (altHUB) is failing → error-level → overall error state.
        #expect(status.health == .error)
        #expect(status.serviceVersion == "1.30.2.4939")

        // Badge: 1 failing-indexer error + 2 health warnings = 3.
        #expect(status.badgeCount == 3)

        // The failing indexer is surfaced as an error Problem named after the indexer, carrying its
        // last error / disabled-until (task §6.2).
        let indexerProblem = try #require(status.problems.first { $0.source == "indexer" })
        #expect(indexerProblem.title == "altHUB")
        #expect(indexerProblem.severity == .error)
        #expect(indexerProblem.detail?.contains("Indexer is currently unavailable due to failures") == true)
        #expect(indexerProblem.detail?.contains("disabled until") == true)

        // Health checks come through as their own problems.
        #expect(status.problems.filter { $0.source == "health" }.count == 2)

        // Headline: "Failing" = 1 (error emphasis), "Indexers" = 2 enabled.
        let failingChip = try #require(status.headline.first { $0.label == "Failing" })
        #expect(failingChip.value == "1")
        #expect(failingChip.emphasis == .error)
        #expect(status.headline.first { $0.label == "Indexers" }?.value == "2")
    }

    @Test("All indexers healthy → healthy state, zero failing, no badge")
    func fetchStatusHealthy() async throws {
        let indexers = try Fixture.data("prowlarr_indexer_healthy")
        let statuses = try Fixture.data("prowlarr_indexerstatus_empty")
        let health = try Fixture.data("prowlarr_health_empty")
        let system = try Fixture.data("prowlarr_system_status")
        let client = ProwlarrClient(context: Fixture.context(
            transport: routingTransport(indexers: indexers, statuses: statuses, health: health, system: system)
        ))

        let status = try await client.fetchStatus()

        #expect(status.health == .healthy)
        #expect(status.badgeCount == 0)
        #expect(status.problems.isEmpty)
        let failingChip = try #require(status.headline.first { $0.label == "Failing" })
        #expect(failingChip.value == "0")
        #expect(failingChip.emphasis == .normal)
        #expect(status.summaryLine == "All 2 indexers healthy")
    }

    @Test("A 401 maps to .unauthorized for both testConnection and fetchStatus")
    func authErrorIsDetected() async {
        let client = ProwlarrClient(context: Fixture.context(
            transport: MockTransport(data: Data("{}".utf8), status: 401)
        ))

        let result = await client.testConnection()
        #expect(result == .failure(.unauthorized))

        await #expect(throws: FleetError.unauthorized) {
            try await client.fetchStatus()
        }
    }

    @Test("A transport timeout propagates as a reachability failure")
    func timeoutPropagates() async {
        let client = ProwlarrClient(context: Fixture.context(transport: MockTransport(error: .timedOut)))

        let result = await client.testConnection()
        #expect(result == .failure(.timedOut))
        if case let .failure(error) = result {
            #expect(error.isReachabilityFailure)
        }
    }

    @Test("testConnection returns the Prowlarr version on success")
    func testConnectionSucceeds() async throws {
        let system = try Fixture.data("prowlarr_system_status")
        let client = ProwlarrClient(context: Fixture.context(transport: MockTransport(data: system)))

        let result = await client.testConnection()
        #expect(result == .success(version: "1.30.2.4939"))
    }

    @Test("Every request carries the X-Api-Key header (and never as a query param)")
    func authHeaderApplied() async throws {
        let system = try Fixture.data("prowlarr_system_status")
        let transport = MockTransport(data: system)
        let client = ProwlarrClient(context: Fixture.context(transport: transport, credential: "secret-key-123"))

        _ = await client.testConnection()

        let request = try #require(transport.sentRequests.first)
        #expect(request.value(forHTTPHeaderField: "X-Api-Key") == "secret-key-123")
        #expect(request.queryValue("apikey") == nil)
    }

    @Test("fetchActivity maps the indexer list, flagging failing indexers with error severity")
    func fetchActivityMapsIndexers() async throws {
        let indexers = try Fixture.data("prowlarr_indexer")
        let statuses = try Fixture.data("prowlarr_indexerstatus")
        let health = try Fixture.data("prowlarr_health")
        let system = try Fixture.data("prowlarr_system_status")
        let client = ProwlarrClient(context: Fixture.context(
            transport: routingTransport(indexers: indexers, statuses: statuses, health: health, system: system)
        ))

        let items = try await client.fetchActivity()
        #expect(items.count == 2)

        let failing = try #require(items.first { $0.title == "altHUB" })
        #expect(failing.severity == .error)
        #expect(failing.status == "Failing")

        let healthy = try #require(items.first { $0.title == "1337x" })
        #expect(healthy.severity == nil)
        #expect(healthy.status == "OK")
    }
}
