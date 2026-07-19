import Foundation
import Testing
@testable import FleetarrKit

/// Verifies each write action builds the correct request — method, path, query, and auth header
/// (spec §6). Uses `MockTransport`'s recorded requests; no network (spec §9.8).
@Suite("Write actions (spec §6, Phase 2)")
struct WriteActionsTests {
    private func okTransport(_ body: String = "") -> MockTransport {
        MockTransport(data: Data(body.utf8), status: 200)
    }

    // MARK: SABnzbd

    @Test("SABnzbd remove deletes the job with del_files")
    func sabRemove() async throws {
        let transport = okTransport(#"{"status": true}"#)
        let client = SABnzbdClient(context: Fixture.context(transport: transport))
        try await client.removeQueueItem(id: "SABnzbd_nzo_abc", blocklist: false)

        let request = try #require(transport.sentRequests.last)
        #expect(request.url?.path == "/api")
        #expect(request.queryValue("mode") == "queue")
        #expect(request.queryValue("name") == "delete")
        #expect(request.queryValue("value") == "SABnzbd_nzo_abc")
        #expect(request.queryValue("del_files") == "1")
        #expect(request.queryValue("apikey") == "test-key")
    }

    @Test("SABnzbd pause/resume use the right mode")
    func sabPauseResume() async throws {
        let transport = okTransport(#"{"status": true}"#)
        let client = SABnzbdClient(context: Fixture.context(transport: transport))
        try await client.setQueuePaused(true)
        #expect(transport.sentRequests.last?.queryValue("mode") == "pause")
        try await client.setQueuePaused(false)
        #expect(transport.sentRequests.last?.queryValue("mode") == "resume")
        try await client.setItemPaused(true, id: "nzo1")
        #expect(transport.sentRequests.last?.queryValue("name") == "pause")
        #expect(transport.sentRequests.last?.queryValue("value") == "nzo1")
    }

    @Test("SABnzbd surfaces an API-error body as a failure")
    func sabActionAuthError() async {
        let transport = okTransport(#"{"status": false, "error": "API Key Incorrect"}"#)
        let client = SABnzbdClient(context: Fixture.context(transport: transport))
        await #expect(throws: FleetError.unauthorized) {
            try await client.setQueuePaused(true)
        }
    }

    // MARK: Sonarr / Radarr

    @Test("Sonarr remove issues DELETE with blocklist and the API key header")
    func sonarrRemove() async throws {
        let transport = okTransport()
        let client = SonarrClient(context: Fixture.context(transport: transport))
        try await client.removeQueueItem(id: "42", blocklist: true)

        let request = try #require(transport.sentRequests.last)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path == "/api/v3/queue/42")
        #expect(request.queryValue("blocklist") == "true")
        #expect(request.queryValue("removeFromClient") == "true")
        #expect(request.value(forHTTPHeaderField: "X-Api-Key") == "test-key")
    }

    @Test("Sonarr queue ActivityItem.id is the bare DELETE target (regression: no 'queue:' prefix)")
    func sonarrActivityIdMatchesDeletePath() async throws {
        let queue = try Fixture.data("sonarr_queue")
        let transport = MockTransport { _ in .response(status: 200, data: queue) }
        let client = SonarrClient(context: Fixture.context(transport: transport))

        let item = try #require(try await client.fetchActivity().first)
        // The id must be the raw numeric queue id, not prefixed — otherwise removal 404s.
        #expect(!item.id.contains(":"))
        try await client.removeQueueItem(id: item.id, blocklist: false)
        #expect(transport.sentRequests.last?.url?.path == "/api/v3/queue/\(item.id)")
    }

    @Test("Radarr remove issues DELETE to the movie queue endpoint")
    func radarrRemove() async throws {
        let transport = okTransport()
        let client = RadarrClient(context: Fixture.context(transport: transport))
        try await client.removeQueueItem(id: "9", blocklist: false)

        let request = try #require(transport.sentRequests.last)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path == "/api/v3/queue/9")
        #expect(request.queryValue("blocklist") == "false")
    }

    // MARK: Seerr

    @Test("Seerr approve/decline POST to the request action endpoints")
    func seerrApproveDecline() async throws {
        let transport = okTransport()
        let client = SeerrClient(context: Fixture.context(transport: transport))

        try await client.approveRequest(id: "7")
        var request = try #require(transport.sentRequests.last)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/v1/request/7/approve")
        #expect(request.value(forHTTPHeaderField: "X-Api-Key") == "test-key")

        try await client.declineRequest(id: "7")
        request = try #require(transport.sentRequests.last)
        #expect(request.url?.path == "/api/v1/request/7/decline")
    }

    // MARK: Plex / Jellyfin

    @Test("Plex terminate passes sessionId + reason with the token header")
    func plexTerminate() async throws {
        let transport = okTransport()
        let client = PlexClient(context: Fixture.context(transport: transport))
        try await client.terminateSession(id: "session-xyz", reason: "Please stop")

        let request = try #require(transport.sentRequests.last)
        #expect(request.url?.path == "/status/sessions/terminate")
        #expect(request.queryValue("sessionId") == "session-xyz")
        #expect(request.queryValue("reason") == "Please stop")
        #expect(request.value(forHTTPHeaderField: "X-Plex-Token") == "test-key")
    }

    @Test("Jellyfin terminate POSTs the Stop playstate command")
    func jellyfinTerminate() async throws {
        let transport = okTransport()
        let client = JellyfinClient(context: Fixture.context(transport: transport))
        try await client.terminateSession(id: "sess1", reason: nil)

        let request = try #require(transport.sentRequests.last)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/Sessions/sess1/Playing/Stop")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("MediaBrowser Token=") == true)
    }
}
