import Foundation
import Testing
@testable import FleetarrKit

@Suite("ServiceContext URL building (spec §9.4)")
struct ServiceContextTests {
    private func context(_ base: String) -> ServiceContext {
        ServiceContext(
            endpoint: InstanceEndpoint(baseURL: URL(string: base)!),
            credential: "k",
            transport: MockTransport(data: Data())
        )
    }

    @Test("Joins a reverse-proxy path prefix with the API path")
    func joinsPathPrefix() throws {
        let url = try #require(context("https://media.example.dev/sonarr").makeURL(path: "/api/v3/health"))
        #expect(url.absoluteString == "https://media.example.dev/sonarr/api/v3/health")
    }

    @Test("Handles a bare host with a non-default port")
    func handlesPortNoPrefix() throws {
        let url = try #require(context("http://10.0.0.5:8080").makeURL(
            path: "/api",
            query: [URLQueryItem(name: "mode", value: "queue")]
        ))
        #expect(url.absoluteString == "http://10.0.0.5:8080/api?mode=queue")
    }

    @Test("Tolerates a trailing slash on the base URL")
    func toleratesTrailingSlash() throws {
        let url = try #require(context("https://host/sab/").makeURL(path: "api"))
        #expect(url.absoluteString == "https://host/sab/api")
    }

    @Test("Applies per-instance extra headers to the request")
    func appliesExtraHeaders() throws {
        let ctx = ServiceContext(
            endpoint: InstanceEndpoint(
                baseURL: URL(string: "https://host")!,
                extraHeaders: ["X-Proxy-Auth": "abc"]
            ),
            credential: "k",
            transport: MockTransport(data: Data())
        )
        let request = try ctx.makeRequest(path: "/api", headers: ["X-Api-Key": "k"])
        #expect(request.value(forHTTPHeaderField: "X-Proxy-Auth") == "abc")
        #expect(request.value(forHTTPHeaderField: "X-Api-Key") == "k")
    }

    @Test("Validate maps status codes to FleetError")
    func validateMapsStatusCodes() {
        #expect(throws: FleetError.unauthorized) {
            _ = try ServiceContext.validate(HTTPResponse(status: 401, data: Data()))
        }
        #expect(throws: FleetError.notFound) {
            _ = try ServiceContext.validate(HTTPResponse(status: 404, data: Data()))
        }
        #expect(throws: FleetError.serverError(status: 503)) {
            _ = try ServiceContext.validate(HTTPResponse(status: 503, data: Data()))
        }
    }
}
