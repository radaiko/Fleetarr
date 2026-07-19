import Foundation

// Decodable shapes for the SABnzbd JSON API (mode=queue / mode=history / mode=version).
//
// SABnzbd returns most numeric fields as *strings* (e.g. "4608.0", "50", "3276.8"), so these are
// decoded as `String?` and parsed by the client. Field names are snake_case in the wire format;
// explicit CodingKeys keep the mapping unambiguous.

struct SABQueueResponse: Decodable {
    let queue: SABQueue
}

struct SABQueue: Decodable {
    let version: String?
    let status: String?
    let paused: Bool?
    let speed: String?
    let kbpersec: String?
    let speedlimit: String?
    let sizeleft: String?
    let size: String?
    let mb: String?
    let mbleft: String?
    let timeleft: String?
    let noofslotsTotal: Int?
    let diskspace1: String?
    let diskspacetotal1: String?
    let slots: [SABQueueSlot]?

    enum CodingKeys: String, CodingKey {
        case version, status, paused, speed, kbpersec, speedlimit, sizeleft, size, mb, mbleft, timeleft
        case noofslotsTotal = "noofslots_total"
        case diskspace1, diskspacetotal1, slots
    }
}

struct SABQueueSlot: Decodable {
    let nzoId: String
    let filename: String
    let status: String
    let category: String?
    let priority: String?
    let size: String?
    let sizeleft: String?
    let mb: String?
    let mbleft: String?
    let percentage: String?
    let timeleft: String?

    enum CodingKeys: String, CodingKey {
        case nzoId = "nzo_id"
        case filename, status, priority, timeleft, size, sizeleft, mb, mbleft, percentage
        case category = "cat"
    }
}

struct SABHistoryResponse: Decodable {
    let history: SABHistory
}

struct SABHistory: Decodable {
    let noofslots: Int?
    let slots: [SABHistorySlot]?
}

struct SABHistorySlot: Decodable {
    let nzoId: String
    let name: String
    let status: String
    let failMessage: String?
    let category: String?
    let size: String?
    let bytes: Int?
    let storage: String?
    let completed: Int?

    enum CodingKeys: String, CodingKey {
        case nzoId = "nzo_id"
        case name, status, category, size, bytes, storage, completed
        case failMessage = "fail_message"
    }
}

struct SABVersionResponse: Decodable {
    let version: String
}

/// SABnzbd signals API-level failures (e.g. a bad API key) with HTTP 200 and a body like
/// `{"status": false, "error": "API Key Incorrect"}` — this captures that shape.
struct SABErrorResponse: Decodable {
    let status: Bool?
    let error: String?
}
