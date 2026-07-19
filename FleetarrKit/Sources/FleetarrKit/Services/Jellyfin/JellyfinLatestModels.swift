import Foundation

// Decodable shape for the Jellyfin recently-added endpoint (GET /Items/Latest), which returns a
// bare JSON *array* of BaseItemDto — unlike most list endpoints there is no { Items, ... } wrapper.
//
// As with the rest of the Jellyfin API the keys are PascalCase, so this uses explicit CodingKeys and
// is decoded without key conversion. Decoding is deliberately tolerant: every field is optional
// because real servers omit many of them (movies have no SeriesName, episodes have no ProductionYear,
// some items lack DateCreated). `DateCreated` is decoded as a raw String rather than a Date so that a
// .NET-style timestamp with 7 fractional-second digits ("…11.0000000Z") never fails the whole array.
struct JellyfinLatestItem: Decodable {
    let id: String?
    let name: String?
    let seriesName: String?
    let type: String?
    let productionYear: Int?
    let dateCreated: String?
    let runTimeTicks: Int64?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case seriesName = "SeriesName"
        case type = "Type"
        case productionYear = "ProductionYear"
        case dateCreated = "DateCreated"
        case runTimeTicks = "RunTimeTicks"
    }
}
