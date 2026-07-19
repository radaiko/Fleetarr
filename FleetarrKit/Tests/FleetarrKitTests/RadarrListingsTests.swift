import Foundation
import Testing
@testable import FleetarrKit

/// Covers Radarr's secondary detail-screen lists (spec §6.1): calendar (Upcoming), recent history,
/// and wanted/missing movies. Each list hits a single distinct endpoint, so a one-body
/// `MockTransport` is enough — the client only issues one request per call.
@Suite("Radarr listings")
struct RadarrListingsTests {
    private func client(_ fixture: String) throws -> (RadarrClient, MockTransport) {
        let transport = MockTransport(data: try Fixture.data(fixture))
        return (RadarrClient(context: Fixture.context(transport: transport)), transport)
    }

    // MARK: UpcomingListing

    @Test("fetchUpcoming maps calendar movies to Available/Upcoming rows with the nearest release")
    func fetchUpcomingMapsCalendar() async throws {
        let (client, transport) = try client("radarr_calendar")
        let items = try await client.fetchUpcoming(days: 14)

        #expect(items.count == 3)

        let dune = try #require(items.first)
        #expect(dune.title == "Dune: Part Two (2024)")
        // hasFile == true → already Available.
        #expect(dune.status == "Available")
        #expect(dune.severity == nil)
        // Nearest = the chronologically earliest of the three dates (inCinemas 2024-03-01).
        #expect(dune.subtitle == "In cinemas · 2024-03-01")
        // Fields carry each present release date plus the Monitored flag (capped at 4).
        #expect(dune.fields.first { $0.label == "Digital" }?.value == "2024-04-16")
        #expect(dune.fields.first { $0.label == "Monitored" }?.value == "Yes")

        // Second movie has no file yet → Upcoming; the shown release is the next FUTURE one
        // (its future digital date), not the past theatrical date that also sits on the record.
        #expect(items[1].status == "Upcoming")
        #expect(items[1].subtitle == "Digital · 2026-08-25")

        // Third movie has only a cinema date and is unmonitored.
        #expect(items[2].subtitle == "In cinemas · 2026-07-22")
        #expect(items[2].fields.first { $0.label == "Monitored" }?.value == "No")

        // The calendar call is windowed and authenticated via the X-Api-Key header.
        let request = try #require(transport.sentRequests.first)
        #expect(request.value(forHTTPHeaderField: "X-Api-Key") == "test-key")
        #expect(request.queryValue("unmonitored") == "false")
        #expect(request.queryValue("start") != nil)
        #expect(request.queryValue("end") != nil)
    }

    // MARK: HistoryListing

    @Test("fetchRecentHistory labels events and flags failures with .error severity")
    func fetchRecentHistoryMapsRecords() async throws {
        let (client, transport) = try client("radarr_history")
        let items = try await client.fetchRecentHistory()

        #expect(items.count == 3)

        // Imported grab, movie embedded → title is the movie name (+ year), no severity.
        let imported = try #require(items.first)
        #expect(imported.title == "Dune: Part Two (2024)")
        #expect(imported.status == "Imported")
        #expect(imported.severity == nil)
        #expect(imported.subtitle == "2026-07-19")
        #expect(imported.fields.first { $0.label == "Quality" }?.value == "Bluray-1080p")
        #expect(imported.fields.first { $0.label == "Client" }?.value == "qBittorrent")
        #expect(imported.fields.first { $0.label == "Release" }?.value == "Dune.Part.Two.2024.1080p.BluRay.x265-GROUP")

        // Grabbed event → Indexer field (not Client).
        #expect(items[1].status == "Grabbed")
        #expect(items[1].fields.first { $0.label == "Indexer" }?.value == "Some Indexer (Prowlarr)")

        // Failed event → .error severity, and with no embedded movie the title falls back to the source.
        let failed = items[2]
        #expect(failed.status == "Download failed")
        #expect(failed.severity == .error)
        #expect(failed.title == "A.Movie.We.Dont.Have.2023.1080p.WEB.H264-FAIL")

        // History is requested newest-first, 30 rows, with the movie joined in.
        let request = try #require(transport.sentRequests.first)
        #expect(request.queryValue("sortKey") == "date")
        #expect(request.queryValue("sortDirection") == "descending")
        #expect(request.queryValue("pageSize") == "30")
        #expect(request.queryValue("includeMovie") == "true")
    }

    // MARK: MissingListing

    @Test("fetchMissing maps wanted movies with monitored/available flags and no severity")
    func fetchMissingMapsRecords() async throws {
        let (client, transport) = try client("radarr_missing_list")
        let items = try await client.fetchMissing()

        #expect(items.count == 2)

        let first = try #require(items.first)
        #expect(first.title == "A Movie We Don't Have Yet (2023)")
        // isAvailable == true → searchable now.
        #expect(first.status == "Wanted")
        #expect(first.severity == nil)
        #expect(first.subtitle == "In cinemas · 2023-06-02")
        #expect(first.fields.first { $0.label == "Monitored" }?.value == "Yes")
        #expect(first.fields.first { $0.label == "Available" }?.value == "Yes")

        // Not yet released → Not yet available.
        #expect(items[1].status == "Not yet available")
        #expect(items[1].fields.first { $0.label == "Available" }?.value == "No")

        // Missing is requested monitored-only, sorted by title, 30 rows.
        let request = try #require(transport.sentRequests.first)
        #expect(request.queryValue("monitored") == "true")
        #expect(request.queryValue("sortKey") == "movieMetadata.sortTitle")
        #expect(request.queryValue("pageSize") == "30")
    }

    // MARK: Tolerant decoding

    @Test("An empty calendar / history / missing payload yields an empty list, not a failure")
    func emptyPayloadsDecodeToEmpty() async throws {
        let emptyArray = RadarrClient(context: Fixture.context(transport: MockTransport(data: Data("[]".utf8))))
        #expect(try await emptyArray.fetchUpcoming(days: 7).isEmpty)

        let emptyPaged = Data(#"{"page":1,"pageSize":30,"totalRecords":0,"records":[]}"#.utf8)
        let history = RadarrClient(context: Fixture.context(transport: MockTransport(data: emptyPaged)))
        #expect(try await history.fetchRecentHistory().isEmpty)

        let missing = RadarrClient(context: Fixture.context(transport: MockTransport(data: emptyPaged)))
        #expect(try await missing.fetchMissing().isEmpty)
    }
}
