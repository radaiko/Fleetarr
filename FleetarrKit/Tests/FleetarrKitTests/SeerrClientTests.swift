import Foundation
import Testing
@testable import FleetarrKit

@Suite("Seerr client")
struct SeerrClientTests {
    /// Routes Seerr requests to the right fixture by path suffix. `/request/count` is checked
    /// before `/request` since the former is a superset path.
    private func routingTransport(status: Data, count: Data, requests: Data) -> MockTransport {
        MockTransport { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/status") { return .response(status: 200, data: status) }
            if path.hasSuffix("/request/count") { return .response(status: 200, data: count) }
            if path.hasSuffix("/request") { return .response(status: 200, data: requests) }
            // Media-detail lookups for the request title/poster (spec §6.3).
            if path.contains("/movie/") {
                return .response(status: 200, data: Data(#"{"title":"Dune: Part Two","posterPath":"/poster.jpg"}"#.utf8))
            }
            if path.contains("/tv/") {
                return .response(status: 200, data: Data(#"{"name":"Andor","posterPath":"/tv.jpg"}"#.utf8))
            }
            return .response(status: 404, data: Data())
        }
    }

    @Test("fetchStatus maps request counts to a healthy tile with a Pending headline")
    func fetchStatusBuildsHeadline() async throws {
        let status = try Fixture.data("seerr_status")
        let count = try Fixture.data("seerr_request_count")
        let requests = try Fixture.data("seerr_requests_pending")
        let transport = routingTransport(status: status, count: count, requests: requests)
        let client = SeerrClient(context: Fixture.context(transport: transport))

        let result = try await client.fetchStatus()

        // Pending requests are activity, not problems — a reachable Seerr is always healthy here.
        #expect(result.health == .healthy)
        #expect(result.problems.isEmpty)
        #expect(result.badgeCount == 0)
        #expect(result.serviceVersion == "1.0.0")
        #expect(result.summaryLine == "3 pending requests")

        let pending = try #require(result.headline.first { $0.label == "Pending" })
        #expect(pending.value == "3")
        #expect(pending.emphasis == .warning)
        #expect(result.headline.first { $0.label == "Available" }?.value == "118")

        // Auth is applied per-call as an X-Api-Key header (never a Bearer prefix).
        let sentKey = transport.sentRequests.first?.value(forHTTPHeaderField: "X-Api-Key")
        #expect(sentKey == "test-key")
    }

    @Test("buildStatus with zero pending uses normal emphasis and a no-pending summary")
    func buildStatusZeroPending() throws {
        let count = try JSONDecoder().decode(
            SeerrRequestCount.self,
            from: Data(#"{"pending":0,"processing":0,"available":118}"#.utf8)
        )
        let client = SeerrClient(context: Fixture.context(transport: MockTransport(data: Data())))

        let result = client.buildStatus(count: count, status: nil)

        #expect(result.health == .healthy)
        #expect(result.summaryLine == "No pending requests")
        let pending = try #require(result.headline.first { $0.label == "Pending" })
        #expect(pending.value == "0")
        #expect(pending.emphasis == .normal)
        // Version is absent when the best-effort /status probe fails.
        #expect(result.serviceVersion == nil)
    }

    @Test("fetchActivity maps pending requests to activity items")
    func fetchActivityMapsRequests() async throws {
        let status = try Fixture.data("seerr_status")
        let count = try Fixture.data("seerr_request_count")
        let requests = try Fixture.data("seerr_requests_pending")
        let client = SeerrClient(context: Fixture.context(transport: routingTransport(status: status, count: count, requests: requests)))

        let items = try await client.fetchActivity()

        #expect(items.count == 2)
        let first = try #require(items.first)
        #expect(first.id == "42")
        // Title + poster resolved from the media-detail endpoint (spec §6.3).
        #expect(first.title == "Dune: Part Two")
        #expect(first.artworkURL == URL(string: "https://image.tmdb.org/t/p/w342/poster.jpg"))
        #expect(first.subtitle == "alexonplex")
        #expect(first.status == "Pending")
        #expect(first.severity == nil)
        #expect(first.fields.first { $0.label == "Type" }?.value == "Movie")
        #expect(first.fields.first { $0.label == "Requested" }?.value == "2026-07-18")

        let second = items[1]
        #expect(second.title == "Andor")
        #expect(second.subtitle == "sam")
        #expect(second.fields.first { $0.label == "Type" }?.value == "TV")
    }

    @Test("A bad key (403 on protected endpoints) fails testConnection even though /status 200s")
    func unauthorizedIsDetected() async throws {
        let statusData = try Fixture.data("seerr_status")
        let authError = try Fixture.data("seerr_auth_error")
        // /status is unauthenticated and 200s even with a bad key; protected endpoints 403.
        let transport = MockTransport { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/status") { return .response(status: 200, data: statusData) }
            return .response(status: 403, data: authError)
        }
        let client = SeerrClient(context: Fixture.context(transport: transport))

        // testConnection validates the key via the protected /request/count, so a bad key fails
        // rather than falsely reporting success off the unauthenticated /status (spec §4).
        let connection = await client.testConnection()
        #expect(connection == .failure(.unauthorized))

        // fetchStatus hits the protected /request/count, so a bad key surfaces as .unauthorized.
        await #expect(throws: FleetError.unauthorized) {
            try await client.fetchStatus()
        }
    }

    @Test("A transport timeout propagates as a reachability failure")
    func timeoutPropagates() async {
        let client = SeerrClient(context: Fixture.context(transport: MockTransport(error: .timedOut)))

        let result = await client.testConnection()
        #expect(result == .failure(.timedOut))
        if case let .failure(error) = result {
            #expect(error.isReachabilityFailure)
        }
    }

    @Test("testConnection returns the Seerr version on success")
    func testConnectionSucceeds() async throws {
        let statusData = try Fixture.data("seerr_status")
        let client = SeerrClient(context: Fixture.context(transport: MockTransport(data: statusData)))

        let result = await client.testConnection()
        #expect(result == .success(version: "1.0.0"))
    }

    @Test("Feature-detects the backing media server (spec §6.3)")
    func detectsMediaServer() async throws {
        let data = try Fixture.data("seerr_public_settings")
        let client = SeerrClient(context: Fixture.context(transport: MockTransport(data: data)))
        #expect(try await client.detectMediaServer() == .plex)
    }

    @Test("fetchStatus names the detected media server in the summary")
    func fetchStatusNamesServer() async throws {
        let count = try Fixture.data("seerr_request_count")
        let settings = try Fixture.data("seerr_public_settings")
        let status = try Fixture.data("seerr_status")
        let transport = MockTransport { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/settings/public") { return .response(status: 200, data: settings) }
            if path.hasSuffix("/status") { return .response(status: 200, data: status) }
            return .response(status: 200, data: count) // /request/count
        }
        let result = try await SeerrClient(context: Fixture.context(transport: transport)).fetchStatus()
        #expect(result.summaryLine?.contains("Plex") == true)
    }
}
