import Foundation
import Testing
@testable import FleetarrKit

@Suite("SABnzbd history listing")
struct SABnzbdListingsTests {
    /// A client whose transport replays the given history fixture for every request. `fetchRecentHistory`
    /// only issues `mode=history`, so a single canned body is sufficient.
    private func makeClient(historyFixture: String) throws -> SABnzbdClient {
        let history = try Fixture.data(historyFixture)
        return SABnzbdClient(context: Fixture.context(transport: MockTransport(data: history)))
    }

    @Test("fetchRecentHistory maps slots and surfaces failures first")
    func mapsAndOrdersHistory() async throws {
        let client = try makeClient(historyFixture: "sabnzbd_history_listing")
        let items = try await client.fetchRecentHistory()

        #expect(items.count == 3)

        // The Failed item is second in server order but must be surfaced first.
        let first = try #require(items.first)
        #expect(first.id == "SABnzbd_nzo_jkl012")
        #expect(first.title == "Some.Show.S03E05.2160p.WEB.H265-GRP")
        #expect(first.status == "Failed")
        #expect(first.severity == .error)
        #expect(first.subtitle == "tv")

        // Size is always present; Failed reason only when there is a fail_message.
        #expect(first.fields.first { $0.label == "Size" }?.value == "3.1 GB")
        let reason = first.fields.first { $0.label == "Failed reason" }
        #expect(reason?.value == "Repair failed, not enough repair blocks (129 short)")
    }

    @Test("Completed and in-progress rows carry no error severity and no Failed-reason field")
    func healthyRowsHaveNoErrorSeverity() async throws {
        let client = try makeClient(historyFixture: "sabnzbd_history_listing")
        let items = try await client.fetchRecentHistory()

        // After ordering, the two non-error rows keep their server order (Completed then Extracting).
        let completed = try #require(items.first { $0.id == "SABnzbd_nzo_ghi789" })
        #expect(completed.title == "Some.Movie.2025.1080p.BluRay.x264-GRP")
        #expect(completed.status == "Completed")
        #expect(completed.severity == nil)
        #expect(completed.subtitle == "movies")
        #expect(completed.fields.first { $0.label == "Size" }?.value == "8.6 GB")
        #expect(completed.fields.contains { $0.label == "Failed reason" } == false)

        let extracting = try #require(items.first { $0.id == "SABnzbd_nzo_mno345" })
        #expect(extracting.status == "Extracting")
        #expect(extracting.severity == nil)
        #expect(extracting.fields.contains { $0.label == "Failed reason" } == false)

        // The healthy rows follow the surfaced failure.
        #expect(items.map(\.id) == ["SABnzbd_nzo_jkl012", "SABnzbd_nzo_ghi789", "SABnzbd_nzo_mno345"])
    }

    @Test("A cosmetic-classified failure is not surfaced as an error")
    func cosmeticFailureIsNotRankedAsError() async throws {
        // The shared history fixture holds a real disk-full failure plus a benign special-character
        // filename failure that the classifier downgrades to cosmetic.
        let client = try makeClient(historyFixture: "sabnzbd_history")
        let items = try await client.fetchRecentHistory()

        #expect(items.count == 3)

        // Only the disk-full row is an .error, so it alone is surfaced first.
        let first = try #require(items.first)
        #expect(first.title == "Some.Movie.2024.1080p.BluRay")
        #expect(first.severity == .error)

        // The special-character filename failure is cosmetic, not error, but still shows its reason.
        let cosmetic = try #require(items.first { $0.title == "Another.Show.S01E01.1080p.WEB" })
        #expect(cosmetic.severity == .cosmetic)
        #expect(cosmetic.fields.contains { $0.label == "Failed reason" })

        // Exactly one row ranks as a surfaced failure.
        #expect(items.filter { $0.severity == .error }.count == 1)
    }

    @Test("A bad API key (HTTP 200 + error body) surfaces as .unauthorized")
    func authErrorPropagates() async throws {
        let authError = try Fixture.data("sabnzbd_auth_error")
        let client = SABnzbdClient(context: Fixture.context(transport: MockTransport(data: authError)))

        await #expect(throws: FleetError.unauthorized) {
            try await client.fetchRecentHistory()
        }
    }

    @Test("An empty history returns no items rather than throwing")
    func emptyHistoryIsEmpty() async throws {
        let empty = Data(#"{"history":{"noofslots":0,"slots":[]}}"#.utf8)
        let client = SABnzbdClient(context: Fixture.context(transport: MockTransport(data: empty)))

        let items = try await client.fetchRecentHistory()
        #expect(items.isEmpty)
    }
}
