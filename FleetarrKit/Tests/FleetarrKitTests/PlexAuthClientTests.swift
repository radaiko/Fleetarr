import Foundation
import Testing
@testable import FleetarrKit

@Suite("Plex plex.tv PIN sign-in (spec §6.5)")
struct PlexAuthClientTests {
    private func client(transport: MockTransport) -> PlexAuthClient {
        PlexAuthClient(clientIdentifier: "test-client-id", transport: transport)
    }

    @Test("requestPin POSTs to plex.tv and decodes id + code with the identity headers")
    func requestPin() async throws {
        let pinData = try Fixture.data("plex_pin")
        let transport = MockTransport(data: pinData, status: 201)
        let pin = try await client(transport: transport).requestPin()

        #expect(pin.id == 123456789)
        #expect(pin.code == "abcd")

        let request = try #require(transport.sentRequests.last)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/v2/pins")
        #expect(request.queryValue("strong") == "true")
        #expect(request.value(forHTTPHeaderField: "X-Plex-Client-Identifier") == "test-client-id")
        #expect(request.value(forHTTPHeaderField: "X-Plex-Product") == "Fleetarr")
    }

    @Test("fetchToken returns nil until signed in, then the token")
    func fetchToken() async throws {
        let pending = try Fixture.data("plex_pin")
        let signedIn = try Fixture.data("plex_pin_token")

        let pendingToken = try await client(transport: MockTransport(data: pending)).fetchToken(pinID: 123456789)
        #expect(pendingToken == nil)

        let readyToken = try await client(transport: MockTransport(data: signedIn)).fetchToken(pinID: 123456789)
        #expect(readyToken == "plex-auth-token-xyz")
    }

    @Test("authURL carries the client id and code")
    func authURL() throws {
        let url = try #require(client(transport: MockTransport(data: Data())).authURL(for: PlexPin(id: 1, code: "wxyz")))
        let string = url.absoluteString
        #expect(string.contains("clientID=test-client-id"))
        #expect(string.contains("code=wxyz"))
    }
}
