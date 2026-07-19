import Foundation
import Testing
@testable import FleetarrKit

@Suite("Plex listings")
struct PlexListingsTests {
    /// Routes `/library/recentlyAdded` to the given fixture; anything else returns an empty body.
    private func recentlyAddedTransport(_ data: Data) -> MockTransport {
        MockTransport { request in
            let path = request.url?.path ?? ""
            if path.contains("/library/recentlyAdded") {
                return .response(status: 200, data: data)
            }
            return .response(status: 200, data: Data("{}".utf8))
        }
    }

    // MARK: fetchRecentlyAdded

    @Test("fetchRecentlyAdded maps movies, episodes and seasons to activity items")
    func mapsRecentlyAdded() async throws {
        let data = try Fixture.data("plex_recently_added")
        let client = PlexClient(context: Fixture.context(transport: recentlyAddedTransport(data)))

        let items = try await client.fetchRecentlyAdded()
        #expect(items.count == 4)

        // Episode: "Show — Episode", type capitalized as subtitle, year as status.
        let episode = try #require(items.first)
        #expect(episode.id == "50123")
        #expect(episode.title == "Game of Thrones — The Rains of Castamere")
        #expect(episode.subtitle == "Episode")
        #expect(episode.status == "2013")
        #expect(episode.severity == nil)
        #expect(episode.progress == nil)
        // The Added field is derived from `addedAt` (epoch seconds) and is non-empty.
        let added = try #require(episode.fields.first { $0.label == "Added" })
        #expect(!added.value.isEmpty)

        // Movie: its own title, "Movie" subtitle, year status.
        let movie = items[1]
        #expect(movie.id == "60234")
        #expect(movie.title == "Blade Runner 2049")
        #expect(movie.subtitle == "Movie")
        #expect(movie.status == "2017")

        // Season: uses its own title (not treated as "show — episode"), no year → no status.
        let season = items[2]
        #expect(season.title == "Season 2")
        #expect(season.subtitle == "Season")
        #expect(season.status == nil)

        // Tolerant of missing fields: no ratingKey falls back to `key`; no year/addedAt → no status
        // and no Added field.
        let sparse = items[3]
        #expect(sparse.id == "/library/metadata/80456")
        #expect(sparse.title == "Untitled Documentary")
        #expect(sparse.status == nil)
        #expect(sparse.fields.contains { $0.label == "Added" } == false)
    }

    @Test("fetchRecentlyAdded returns an empty list for an empty library feed")
    func mapsEmptyRecentlyAdded() async throws {
        let data = try Fixture.data("plex_recently_added_empty")
        let client = PlexClient(context: Fixture.context(transport: recentlyAddedTransport(data)))

        let items = try await client.fetchRecentlyAdded()
        #expect(items.isEmpty)
    }

    @Test("fetchRecentlyAdded applies the Plex token, JSON Accept, and a container-size cap")
    func appliesHeadersAndCap() async throws {
        let data = try Fixture.data("plex_recently_added")
        let transport = recentlyAddedTransport(data)
        let client = PlexClient(context: Fixture.context(transport: transport, credential: "plex-secret-token"))

        _ = try await client.fetchRecentlyAdded()

        let request = try #require(
            transport.sentRequests.first { $0.url?.path.contains("/library/recentlyAdded") == true }
        )
        #expect(request.value(forHTTPHeaderField: "X-Plex-Token") == "plex-secret-token")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        // The feed is capped so a large library can't produce an unbounded payload.
        #expect(request.value(forHTTPHeaderField: "X-Plex-Container-Size") == "30")
    }
}
