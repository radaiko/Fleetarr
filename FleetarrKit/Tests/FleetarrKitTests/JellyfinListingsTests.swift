import Foundation
import Testing
@testable import FleetarrKit

@Suite("Jellyfin listings")
struct JellyfinListingsTests {
    @Test("fetchRecentlyAdded maps BaseItemDto array to activity items")
    func mapsRecentlyAdded() async throws {
        let latest = try Fixture.data("jellyfin_latest")
        let client = JellyfinClient(context: Fixture.context(transport: MockTransport(data: latest)))

        let items = try await client.fetchRecentlyAdded()
        #expect(items.count == 4)

        // Movie: no SeriesName → title is just the name; subtitle is the Type; status is the year.
        let dune = try #require(items.first)
        #expect(dune.title == "Dune: Part Two")
        #expect(dune.subtitle == "Movie")
        #expect(dune.status == "2024")
        #expect(dune.severity == nil)          // a library addition is not a problem
        #expect(dune.progress == nil)          // no playback progress for this list
        #expect(dune.fields.first { $0.label == "Added" }?.value == "Jul 18, 2026")
        #expect(dune.fields.first { $0.label == "Runtime" }?.value == "2h 45m")

        // Episode: SeriesName present → "<Series> — <Name>"; no ProductionYear → nil status.
        let severance = items[1]
        #expect(severance.title == "Severance — Chapter 7")
        #expect(severance.subtitle == "Episode")
        #expect(severance.status == nil)
        #expect(severance.fields.first { $0.label == "Added" }?.value == "Jul 17, 2026")
        #expect(severance.fields.first { $0.label == "Runtime" }?.value == "46m")

        // Series with no runtime: the Runtime field is omitted, but Added still renders.
        let bear = items[2]
        #expect(bear.title == "The Bear")
        #expect(bear.subtitle == "Series")
        #expect(bear.status == "2022")
        #expect(bear.fields.contains { $0.label == "Added" && $0.value == "Jul 16, 2026" })
        #expect(!bear.fields.contains { $0.label == "Runtime" })
    }

    @Test("Tolerant decoding: missing Id/DateCreated still yields a stable item")
    func tolerantForSparseItems() async throws {
        let latest = try Fixture.data("jellyfin_latest")
        let client = JellyfinClient(context: Fixture.context(transport: MockTransport(data: latest)))

        let items = try await client.fetchRecentlyAdded()
        let nosferatu = items[3]

        #expect(nosferatu.title == "Nosferatu")
        #expect(nosferatu.subtitle == "Movie")
        #expect(nosferatu.status == nil)                        // no ProductionYear
        #expect(nosferatu.id == "Nosferatu|")                   // stable fallback when Id is absent
        #expect(nosferatu.fields.first { $0.label == "Added" }?.value == "—")  // no DateCreated
        #expect(!nosferatu.fields.contains { $0.label == "Runtime" })
    }

    @Test("fetchRecentlyAdded caps the request and carries the MediaBrowser token")
    func requestShape() async throws {
        let latest = try Fixture.data("jellyfin_latest")
        let transport = MockTransport(data: latest)
        let client = JellyfinClient(context: Fixture.context(transport: transport, credential: "secret-token"))

        _ = try await client.fetchRecentlyAdded()

        let request = try #require(transport.sentRequests.first)
        #expect(request.url?.path.hasSuffix("/Items/Latest") == true)
        #expect(request.queryValue("Limit") == "30")
        // We rely on the server inferring the user from the token: no userId is sent.
        #expect(request.queryValue("userId") == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("MediaBrowser Token=\"secret-token\"") == true)
    }

    @Test("A bad token (HTTP 401) surfaces as .unauthorized")
    func unauthorizedPropagates() async {
        let client = JellyfinClient(context: Fixture.context(transport: MockTransport(data: Data(), status: 401)))

        await #expect(throws: FleetError.unauthorized) {
            try await client.fetchRecentlyAdded()
        }
    }
}
