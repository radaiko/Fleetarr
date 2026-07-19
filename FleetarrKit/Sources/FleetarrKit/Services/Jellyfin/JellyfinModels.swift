import Foundation

// Decodable shapes for the Jellyfin server-root REST API (GET /System/Info, GET /Sessions).
//
// Jellyfin's JSON keys are PascalCase (ServerName, NowPlayingItem, RunTimeTicks, …), so these
// types use explicit CodingKeys and are decoded with a decoder that does NOT apply key conversion.
// Decoding is deliberately tolerant — every field is optional because real servers omit many of
// them (idle sessions have no NowPlayingItem, non-transcoding sessions have no TranscodingInfo).
//
// All Jellyfin time values are .NET ticks: Int64, 10,000,000 ticks per second. A 2h title is
// ~72,000,000,000 ticks, which overflows Int32 — these are decoded as Int64.

/// Server identity from GET /System/Info (or the unauthenticated /System/Info/Public).
struct JellyfinSystemInfo: Decodable {
    let serverName: String?
    let version: String?

    enum CodingKeys: String, CodingKey {
        case serverName = "ServerName"
        case version = "Version"
    }
}

/// One element of the GET /Sessions array. A session is "playing" iff `nowPlayingItem != nil`;
/// idle/control-only clients appear here too with a nil `nowPlayingItem`.
struct JellyfinSession: Decodable {
    let id: String?
    let userName: String?
    let client: String?
    let deviceName: String?
    let nowPlayingItem: JellyfinNowPlayingItem?
    let playState: JellyfinPlayState?
    let transcodingInfo: JellyfinTranscodingInfo?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case userName = "UserName"
        case client = "Client"
        case deviceName = "DeviceName"
        case nowPlayingItem = "NowPlayingItem"
        case playState = "PlayState"
        case transcodingInfo = "TranscodingInfo"
    }
}

/// The item currently playing in a session (BaseItemDto subset).
struct JellyfinNowPlayingItem: Decodable {
    let name: String?
    let seriesName: String?
    let seasonName: String?
    let indexNumber: Int?
    let parentIndexNumber: Int?
    let type: String?
    let runTimeTicks: Int64?

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case seriesName = "SeriesName"
        case seasonName = "SeasonName"
        case indexNumber = "IndexNumber"
        case parentIndexNumber = "ParentIndexNumber"
        case type = "Type"
        case runTimeTicks = "RunTimeTicks"
    }
}

/// Playback state for a session (PlayerStateInfo subset).
struct JellyfinPlayState: Decodable {
    let positionTicks: Int64?
    /// "DirectPlay" | "DirectStream" | "Transcode" — the only reliable way to tell playback type.
    let playMethod: String?
    let isPaused: Bool?

    enum CodingKeys: String, CodingKey {
        case positionTicks = "PositionTicks"
        case playMethod = "PlayMethod"
        case isPaused = "IsPaused"
    }
}

/// Present only when the server is touching the stream (remux or transcode).
struct JellyfinTranscodingInfo: Decodable {
    /// Why the server is transcoding, e.g. ["VideoCodecNotSupported"]. Older/Emby-era servers may
    /// serialize this as a single comma-joined string instead of an array, so decode defensively.
    let transcodeReasons: [String]?
    let bitrate: Int?
    let isVideoDirect: Bool?
    let isAudioDirect: Bool?

    enum CodingKeys: String, CodingKey {
        case transcodeReasons = "TranscodeReasons"
        case bitrate = "Bitrate"
        case isVideoDirect = "IsVideoDirect"
        case isAudioDirect = "IsAudioDirect"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.bitrate = try container.decodeIfPresent(Int.self, forKey: .bitrate)
        self.isVideoDirect = try container.decodeIfPresent(Bool.self, forKey: .isVideoDirect)
        self.isAudioDirect = try container.decodeIfPresent(Bool.self, forKey: .isAudioDirect)

        if let array = try? container.decode([String].self, forKey: .transcodeReasons) {
            self.transcodeReasons = array
        } else if let joined = try? container.decode(String.self, forKey: .transcodeReasons) {
            self.transcodeReasons = joined
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        } else {
            self.transcodeReasons = nil
        }
    }
}
