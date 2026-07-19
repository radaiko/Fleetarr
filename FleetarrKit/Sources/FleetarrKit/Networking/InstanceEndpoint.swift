import Foundation

/// The transport-level configuration for talking to one instance (spec §4, §9.4).
public struct InstanceEndpoint: Sendable, Equatable, Hashable {
    /// Scheme + host + port + optional path prefix, e.g. `https://media.example.dev/sonarr`.
    public var baseURL: URL
    /// Trust self-signed / private-CA certs for this instance's host only (spec §9.3).
    public var allowInsecureTLS: Bool
    /// Static headers to inject on every request (HTTP Basic, reverse-proxy headers).
    public var extraHeaders: [String: String]
    /// Per-request timeout, in seconds. Kept short so an unreachable instance fails fast and
    /// never delays other tiles (spec §3.2, §9.1).
    public var timeout: TimeInterval

    public init(
        baseURL: URL,
        allowInsecureTLS: Bool = false,
        extraHeaders: [String: String] = [:],
        timeout: TimeInterval = 15
    ) {
        self.baseURL = baseURL
        self.allowInsecureTLS = allowInsecureTLS
        self.extraHeaders = extraHeaders
        self.timeout = timeout
    }

    /// Builds an endpoint from a configured instance, or `nil` if its base URL is invalid.
    public init?(instance: FleetInstance, timeout: TimeInterval = 15) {
        guard let url = instance.baseURL else { return nil }
        self.init(
            baseURL: url,
            allowInsecureTLS: instance.allowInsecureTLS,
            extraHeaders: instance.extraHeaders,
            timeout: timeout
        )
    }
}
