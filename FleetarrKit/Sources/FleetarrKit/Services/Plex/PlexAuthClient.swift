import Foundation

/// A PIN issued by plex.tv for the OAuth-style sign-in flow (spec §6.5).
public struct PlexPin: Sendable, Equatable {
    public let id: Int
    public let code: String
}

/// Drives Plex's plex.tv PIN sign-in flow so the user doesn't have to hand-enter a token (spec §6.5):
///
/// 1. `requestPin()` → `POST https://plex.tv/api/v2/pins?strong=true` returns an id + short code.
/// 2. `authURL(for:)` → open it in the browser; the user signs in to plex.tv.
/// 3. Poll `fetchToken(pinID:)` → `GET https://plex.tv/api/v2/pins/{id}` until `authToken` appears.
///
/// The resulting token is stored as the Plex instance's credential (in the Keychain, spec §3.3).
public struct PlexAuthClient: Sendable {
    private let context: ServiceContext
    private let clientIdentifier: String
    private let product: String

    public init(
        clientIdentifier: String,
        product: String = "Fleetarr",
        transport: (any HTTPTransport)? = nil
    ) {
        // plex.tv is a fixed host, distinct from the user's Plex server.
        let endpoint = InstanceEndpoint(baseURL: URL(string: "https://plex.tv")!)
        self.context = ServiceContext(
            endpoint: endpoint,
            credential: "",
            transport: transport ?? URLSessionTransport(endpoint: endpoint)
        )
        self.clientIdentifier = clientIdentifier
        self.product = product
    }

    private var headers: [String: String] {
        [
            "X-Plex-Client-Identifier": clientIdentifier,
            "X-Plex-Product": product,
            "Accept": "application/json",
        ]
    }

    /// Requests a new PIN from plex.tv.
    public func requestPin() async throws(FleetError) -> PlexPin {
        let response = try await context.fetchJSON(
            PlexPinResponse.self,
            path: "/api/v2/pins",
            method: "POST",
            query: [URLQueryItem(name: "strong", value: "true")],
            headers: headers
        )
        return PlexPin(id: response.id, code: response.code)
    }

    /// The plex.tv sign-in URL to open in the browser for a given PIN.
    public func authURL(for pin: PlexPin) -> URL? {
        var components = URLComponents(string: "https://app.plex.tv/auth")
        components?.fragment =
            "?clientID=\(clientIdentifier)&code=\(pin.code)&context[device][product]=\(product)"
        return components?.url
    }

    /// Polls a PIN; returns the auth token once the user has signed in, else `nil` (keep polling).
    public func fetchToken(pinID: Int) async throws(FleetError) -> String? {
        let response = try await context.fetchJSON(
            PlexPinResponse.self,
            path: "/api/v2/pins/\(pinID)",
            headers: headers
        )
        guard let token = response.authToken, !token.isEmpty else { return nil }
        return token
    }
}

struct PlexPinResponse: Decodable {
    let id: Int
    let code: String
    let authToken: String?
}
