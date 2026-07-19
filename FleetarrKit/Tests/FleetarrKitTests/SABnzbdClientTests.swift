import Foundation
import Testing
@testable import FleetarrKit

@Suite("SABnzbd client")
struct SABnzbdClientTests {
    /// Routes SABnzbd `mode=queue` / `mode=history` requests to the right fixture.
    private func routingTransport(queue: Data, history: Data) -> MockTransport {
        MockTransport { request in
            switch request.queryValue("mode") {
            case "queue": return .response(status: 200, data: queue)
            case "history": return .response(status: 200, data: history)
            default: return .response(status: 200, data: queue)
            }
        }
    }

    @Test("fetchStatus classifies queue + history into problems and health")
    func fetchStatusBuildsProblems() async throws {
        let queue = try Fixture.data("sabnzbd_queue")
        let history = try Fixture.data("sabnzbd_history")
        let client = SABnzbdClient(context: Fixture.context(transport: routingTransport(queue: queue, history: history)))

        let status = try await client.fetchStatus()

        // History has one genuine error (unpack/disk-full) → overall error state.
        #expect(status.health == .error)
        // Badge counts: 1 paused warning (queue) + 1 error (history). The cosmetic history item and
        // the healthy downloading item are excluded.
        #expect(status.badgeCount == 2)
        #expect(status.serviceVersion == "4.3.2")

        // The cosmetic problem exists but does not count toward the badge (spec §6.4).
        let cosmeticCount = status.problems.filter { $0.severity == .cosmetic }.count
        #expect(cosmeticCount == 1)

        // Headline chips include speed + queue count.
        #expect(status.headline.contains { $0.label == "Speed" })
        #expect(status.headline.first { $0.label == "Queue" }?.value == "2")
    }

    @Test("A bad API key (HTTP 200 + error body) maps to .unauthorized")
    func authErrorIsDetected() async throws {
        let authError = try Fixture.data("sabnzbd_auth_error")
        let client = SABnzbdClient(context: Fixture.context(transport: MockTransport(data: authError)))

        await #expect(throws: FleetError.unauthorized) {
            try await client.fetchStatus()
        }

        let result = await client.testConnection()
        #expect(result == .failure(.unauthorized))
    }

    @Test("A transport timeout propagates as a reachability failure")
    func timeoutPropagates() async {
        let client = SABnzbdClient(context: Fixture.context(transport: MockTransport(error: .timedOut)))

        let result = await client.testConnection()
        #expect(result == .failure(.timedOut))
        if case let .failure(error) = result {
            #expect(error.isReachabilityFailure)
        }
    }

    @Test("testConnection returns the SABnzbd version on success")
    func testConnectionSucceeds() async throws {
        let queue = try Fixture.data("sabnzbd_queue")
        let client = SABnzbdClient(context: Fixture.context(transport: MockTransport(data: queue)))

        let result = await client.testConnection()
        #expect(result == .success(version: "4.3.2"))
    }

    @Test("fetchActivity maps queue slots to activity items with progress")
    func fetchActivityMapsSlots() async throws {
        let queue = try Fixture.data("sabnzbd_queue")
        let client = SABnzbdClient(context: Fixture.context(transport: MockTransport(data: queue)))

        let items = try await client.fetchActivity()
        #expect(items.count == 2)
        let downloading = try #require(items.first)
        #expect(downloading.title == "Some.Show.S02E05.1080p.WEB")
        #expect(downloading.progress == 0.6)
    }
}
