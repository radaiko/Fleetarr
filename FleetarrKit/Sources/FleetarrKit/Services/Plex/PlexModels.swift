import Foundation

// Decodable shapes for the Plex Media Server HTTP API (GET /identity, GET /status/sessions).
//
// Plex returns XML by default; the client sends `Accept: application/json` to get JSON. Every
// payload is wrapped in a `MediaContainer` object. In JSON, `User`, `Player`, `Session`, and
// `TranscodeSession` are single OBJECTS (not arrays) — decoded here as optional nested structs.
// Every field is optional: real servers omit fields depending on client, media type, and stream
// mode (a pure Direct Play session has no `TranscodeSession` at all).

// MARK: - /identity

struct PlexIdentityResponse: Decodable {
    let mediaContainer: PlexIdentity

    enum CodingKeys: String, CodingKey {
        case mediaContainer = "MediaContainer"
    }
}

struct PlexIdentity: Decodable {
    let size: Int?
    let claimed: Bool?
    let machineIdentifier: String?
    let version: String?
}

// MARK: - /status/sessions

struct PlexSessionsResponse: Decodable {
    let mediaContainer: PlexSessions

    enum CodingKeys: String, CodingKey {
        case mediaContainer = "MediaContainer"
    }
}

struct PlexSessions: Decodable {
    /// The number of active sessions Plex reports (equals `Metadata.count` in practice).
    let size: Int?
    let metadata: [PlexSession]?

    enum CodingKeys: String, CodingKey {
        case size
        case metadata = "Metadata"
    }
}

struct PlexSession: Decodable {
    let type: String?
    let title: String?
    let grandparentTitle: String?
    let parentTitle: String?
    let ratingKey: String?
    let sessionKey: String?
    /// Poster/thumbnail paths for the now-playing item (spec §6.5). `grandparentThumb` is the show
    /// poster for episodes; `thumb` is the item's own image.
    let thumb: String?
    let grandparentThumb: String?
    /// Playback position, in milliseconds.
    let viewOffset: Int?
    /// Media duration, in milliseconds.
    let duration: Int?
    let user: PlexUser?
    let player: PlexPlayer?
    let session: PlexSessionInfo?
    /// Present only when the server is transcoding/remuxing this stream; absent for Direct Play.
    let transcodeSession: PlexTranscodeSession?

    enum CodingKeys: String, CodingKey {
        case type, title, grandparentTitle, parentTitle, ratingKey, sessionKey, viewOffset, duration
        case thumb, grandparentThumb
        case user = "User"
        case player = "Player"
        case session = "Session"
        case transcodeSession = "TranscodeSession"
    }

    /// A stream is transcoding only when Plex is actually transcoding the video or audio (spec §6.5).
    /// A `TranscodeSession` can also be attached for a Direct Stream (remux, `copy`) — that is not a
    /// transcode, so classify by the decision fields rather than the session's mere presence.
    var isTranscoding: Bool {
        [transcodeSession?.videoDecision, transcodeSession?.audioDecision]
            .contains { $0?.lowercased() == "transcode" }
    }
}

struct PlexUser: Decodable {
    let id: String?
    let title: String?
    let thumb: String?
}

struct PlexPlayer: Decodable {
    let address: String?
    let device: String?
    let platform: String?
    let product: String?
    let profile: String?
    /// "playing" | "paused" | "buffering".
    let state: String?
    let title: String?
}

struct PlexSessionInfo: Decodable {
    let id: String?
    /// Server-reserved bandwidth estimate, in kilobits per second.
    let bandwidth: Int?
    /// "lan" | "wan".
    let location: String?
}

struct PlexTranscodeSession: Decodable {
    /// "directplay" | "copy" | "transcode".
    let videoDecision: String?
    let audioDecision: String?
    let transcodeHwRequested: Bool?
    let transcodeHwFullPipeline: Bool?
    let transcodeHwEncoding: String?
}
