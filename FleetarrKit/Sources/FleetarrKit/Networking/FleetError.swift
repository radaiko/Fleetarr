import Foundation

/// A normalized networking/decoding error for a service call.
///
/// The whole point of this taxonomy is to let the UI distinguish *"the server actively refused /
/// errored"* from *"the request timed out / I'm not on the right network"* (spec §4, §9.4), which
/// currently look identical from the outside and are a real source of confusion (spec §6.1).
public enum FleetError: Error, Sendable, Equatable, Hashable {
    /// The instance's base URL could not be parsed or combined with the request path.
    case invalidURL
    /// The request exceeded its timeout.
    case timedOut
    /// The host refused the connection or is down (connection refused, host unreachable).
    case cannotConnect
    /// DNS resolution failed — the hostname couldn't be resolved.
    case dnsFailure
    /// A TLS/certificate failure (self-signed without a trust override, expired cert, etc.).
    case tlsFailure(String?)
    /// The device has no network connectivity at all.
    case offline
    /// Authentication failed — HTTP 401 or 403 (bad or missing API key/token).
    case unauthorized
    /// The endpoint was not found — HTTP 404 (often a wrong base URL / path prefix).
    case notFound
    /// The server returned a non-success status code not otherwise classified.
    case serverError(status: Int)
    /// The response body could not be decoded into the expected shape.
    case decoding(String)
    /// The request was cancelled (e.g. a superseded refresh).
    case cancelled
    /// Any other transport-level failure, with a short non-secret description.
    case transport(String)

    /// True when the failure means "can't reach the server" rather than "server reported an
    /// error" — i.e. it maps to ``HealthState/unreachable`` (spec §4).
    public var isReachabilityFailure: Bool {
        switch self {
        case .timedOut, .cannotConnect, .dnsFailure, .tlsFailure, .offline, .invalidURL, .cancelled, .transport:
            return true
        case .unauthorized, .notFound, .serverError, .decoding:
            return false
        }
    }

    /// The ``HealthState`` this error implies for an instance.
    public var impliedHealthState: HealthState {
        isReachabilityFailure ? .unreachable : .error
    }

    /// A concise, user-facing explanation. Never contains credentials or full request URLs.
    public var userMessage: String {
        switch self {
        case .invalidURL: return "The server address isn't a valid URL."
        case .timedOut: return "The request timed out — the server may be down or you may not be on its network."
        case .cannotConnect: return "Couldn't connect — the server refused the connection or is offline."
        case .dnsFailure: return "Couldn't resolve the server's hostname (DNS failure)."
        case .tlsFailure(let detail):
            if let detail, !detail.isEmpty {
                return "TLS/certificate error: \(detail). Enable the self-signed-cert override for this instance if that's expected."
            }
            return "TLS/certificate error. Enable the self-signed-cert override for this instance if that's expected."
        case .offline: return "This device appears to be offline."
        case .unauthorized: return "Authentication failed — check the API key or token for this instance."
        case .notFound: return "The service endpoint wasn't found (404) — check the base URL and any path prefix."
        case .serverError(let status): return "The server returned an error (HTTP \(status))."
        case .decoding: return "The server's response couldn't be read — it may be a different service or version."
        case .cancelled: return "The request was cancelled."
        case .transport(let detail): return "Network error: \(detail)."
        }
    }

    /// Maps a `URLError` to a `FleetError`, without leaking the failing URL.
    public static func from(urlError error: URLError) -> FleetError {
        switch error.code {
        case .timedOut:
            return .timedOut
        case .cannotConnectToHost:
            return .cannotConnect
        case .cannotFindHost, .dnsLookupFailed:
            return .dnsFailure
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            return .offline
        case .secureConnectionFailed,
             .serverCertificateUntrusted,
             .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid,
             .clientCertificateRejected,
             .clientCertificateRequired,
             .appTransportSecurityRequiresSecureConnection:
            return .tlsFailure(error.localizedDescription)
        case .cancelled:
            return .cancelled
        case .badURL, .unsupportedURL:
            return .invalidURL
        default:
            return .transport(error.code.friendlyName)
        }
    }
}

private extension URLError.Code {
    /// A short, stable, non-secret label for a URLError code (avoids leaking URLs in messages).
    var friendlyName: String {
        switch self {
        case .cannotConnectToHost: return "cannot connect to host"
        case .resourceUnavailable: return "resource unavailable"
        case .httpTooManyRedirects: return "too many redirects"
        case .redirectToNonExistentLocation: return "bad redirect"
        case .zeroByteResource: return "empty response"
        default: return "connection failed"
        }
    }
}
