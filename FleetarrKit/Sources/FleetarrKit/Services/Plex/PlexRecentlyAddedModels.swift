import Foundation

// Decodable shapes for the Plex Media Server "recently added" feed (GET /library/recentlyAdded).
//
// Like the other PMS endpoints, the payload is wrapped in a `MediaContainer` and returned as JSON
// only when `Accept: application/json` is sent. Every field is optional — real servers omit fields
// depending on the item's media type (a movie has no `grandparentTitle`/`parentTitle`; an unmatched
// item may lack `year`). `addedAt` is a Unix epoch **in seconds**.

struct PlexRecentlyAddedResponse: Decodable {
    let mediaContainer: PlexRecentlyAdded

    enum CodingKeys: String, CodingKey {
        case mediaContainer = "MediaContainer"
    }
}

struct PlexRecentlyAdded: Decodable {
    let size: Int?
    let metadata: [PlexLibraryItem]?

    enum CodingKeys: String, CodingKey {
        case size
        case metadata = "Metadata"
    }
}

/// One recently-added library item: a movie, an episode, or a season.
struct PlexLibraryItem: Decodable {
    let ratingKey: String?
    let key: String?
    /// "movie" | "episode" | "season" | …
    let type: String?
    let title: String?
    /// The show title for an episode/season (absent for movies).
    let grandparentTitle: String?
    /// The season title for an episode (absent for movies).
    let parentTitle: String?
    let year: Int?
    /// When the item was added to the library, as a Unix epoch in **seconds**.
    let addedAt: Int?
    let updatedAt: Int?
    let summary: String?
}
