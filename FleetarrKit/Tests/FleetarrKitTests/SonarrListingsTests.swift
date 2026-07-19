import Foundation
import Testing
@testable import FleetarrKit

@Suite("Sonarr detail-screen listings")
struct SonarrListingsTests {
    // MARK: Upcoming (calendar)

    @Test("fetchUpcoming maps calendar episodes to activity items")
    func upcomingMapsCalendar() async throws {
        let client = SonarrClient(context: Fixture.context(
            transport: MockTransport(data: try Fixture.data("sonarr_calendar"))
        ))

        let items = try await client.fetchUpcoming(days: 7)
        #expect(items.count == 2)

        let first = try #require(items.first)
        #expect(first.title == "Example Series — S02E06 Fallout")
        #expect(first.subtitle == "2026-07-23")
        #expect(first.status == "Upcoming")
        #expect(first.severity == nil)
        #expect(first.fields.first { $0.label == "Air date" }?.value == "2026-07-23")
        #expect(first.fields.first { $0.label == "Monitored" }?.value == "Yes")

        // hasFile == true → "Downloaded"; monitored == false → "No".
        let second = items[1]
        #expect(second.title == "Some Show — S03E08 Aftermath")
        #expect(second.status == "Downloaded")
        #expect(second.fields.first { $0.label == "Monitored" }?.value == "No")
    }

    @Test("fetchUpcoming is reachable through the UpcomingListing capability")
    func upcomingIsFeatureDetectable() async throws {
        // Mirror the detail screen's feature detection: it holds an `any FleetService` and probes
        // for each listing capability with `as?`.
        let service: any FleetService = SonarrClient(context: Fixture.context(
            transport: MockTransport(data: try Fixture.data("sonarr_calendar"))
        ))

        let listing = try #require(service as? any UpcomingListing)
        let items = try await listing.fetchUpcoming(days: 14)
        #expect(items.count == 2)
    }

    // MARK: History

    @Test("fetchRecentHistory maps events, flagging failures with .error")
    func historyMapsEvents() async throws {
        let client = SonarrClient(context: Fixture.context(
            transport: MockTransport(data: try Fixture.data("sonarr_history"))
        ))

        let items = try await client.fetchRecentHistory()
        #expect(items.count == 3)

        let imported = try #require(items.first)
        #expect(imported.title == "Some.Show.S03E07.1080p.WEB.h264-GROUP")
        #expect(imported.status == "Imported")
        #expect(imported.severity == nil)
        #expect(imported.subtitle == "2026-07-19")
        #expect(imported.fields.first { $0.label == "Quality" }?.value == "WEBDL-1080p")
        #expect(imported.fields.first { $0.label == "Indexer" }?.value == "NZBgeek")

        #expect(items.contains { $0.status == "Grabbed" && $0.severity == nil })

        // downloadFailed → readable "Download failed" with .error severity.
        let failed = try #require(items.first { $0.severity == .error })
        #expect(failed.status == "Download failed")
        #expect(failed.title == "Broken.Show.S04E11.2160p.WEB.h265-GROUP")
    }

    @Test("fetchRecentHistory requests the newest 30 events by date")
    func historySendsPagingQuery() async throws {
        let transport = MockTransport(data: try Fixture.data("sonarr_history"))
        let client = SonarrClient(context: Fixture.context(transport: transport, credential: "secret-key"))

        _ = try await client.fetchRecentHistory()

        let request = try #require(transport.sentRequests.first)
        #expect(request.queryValue("pageSize") == "30")
        #expect(request.queryValue("sortKey") == "date")
        #expect(request.queryValue("sortDirection") == "descending")
        // The API key travels in the header, never in the URL (spec §4).
        #expect(request.value(forHTTPHeaderField: "X-Api-Key") == "secret-key")
        #expect(request.url?.query?.contains("secret-key") != true)
    }

    // MARK: Missing

    @Test("fetchMissing maps wanted episodes with series titles")
    func missingMapsEpisodes() async throws {
        let client = SonarrClient(context: Fixture.context(
            transport: MockTransport(data: try Fixture.data("sonarr_missing_listing"))
        ))

        let items = try await client.fetchMissing()
        #expect(items.count == 2)

        let first = try #require(items.first)
        #expect(first.title == "Example Series — S02E05 The Reckoning")
        #expect(first.subtitle == "2026-07-16")
        #expect(first.status == "Missing")
        #expect(first.fields.first { $0.label == "Monitored" }?.value == "Yes")
        #expect(first.id == "missing:34988")
    }

    @Test("fetchMissing asks for monitored episodes with their series")
    func missingSendsQuery() async throws {
        let transport = MockTransport(data: try Fixture.data("sonarr_missing_listing"))
        let client = SonarrClient(context: Fixture.context(transport: transport))

        _ = try await client.fetchMissing()

        let request = try #require(transport.sentRequests.first)
        #expect(request.queryValue("monitored") == "true")
        #expect(request.queryValue("includeSeries") == "true")
        #expect(request.queryValue("pageSize") == "30")
    }

    // MARK: Tolerant decoding

    @Test("Empty payloads decode to empty lists, not errors")
    func emptyListsAreTolerated() async throws {
        let calendarClient = SonarrClient(context: Fixture.context(
            transport: MockTransport(data: Data("[]".utf8))
        ))
        #expect(try await calendarClient.fetchUpcoming(days: 7).isEmpty)

        let pagedClient = SonarrClient(context: Fixture.context(
            transport: MockTransport(data: Data(#"{"totalRecords":0,"records":[]}"#.utf8))
        ))
        #expect(try await pagedClient.fetchRecentHistory().isEmpty)
        #expect(try await pagedClient.fetchMissing().isEmpty)
    }
}
