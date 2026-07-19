import Foundation
@testable import FleetarrKit

/// A test double for ``HTTPTransport`` that returns canned responses or errors, so service clients
/// can be unit-tested against recorded payloads without hitting the network (spec §9.8).
final class MockTransport: HTTPTransport, @unchecked Sendable {
    enum Outcome {
        case response(status: Int, data: Data)
        case failure(FleetError)
    }

    private let handler: @Sendable (URLRequest) -> Outcome

    /// Records every request that was sent, for assertions.
    private let box = RequestBox()

    init(handler: @escaping @Sendable (URLRequest) -> Outcome) {
        self.handler = handler
    }

    /// Always returns the same body with HTTP 200.
    convenience init(data: Data, status: Int = 200) {
        self.init(handler: { _ in .response(status: status, data: data) })
    }

    /// Always fails with the given error.
    convenience init(error: FleetError) {
        self.init(handler: { _ in .failure(error) })
    }

    var sentRequests: [URLRequest] { box.requests }

    func send(_ request: URLRequest) async throws(FleetError) -> HTTPResponse {
        box.record(request)
        switch handler(request) {
        case let .response(status, data):
            return HTTPResponse(status: status, data: data)
        case let .failure(error):
            throw error
        }
    }
}

private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    func record(_ request: URLRequest) {
        lock.lock(); defer { lock.unlock() }
        storage.append(request)
    }

    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

enum Fixture {
    /// Loads a JSON fixture from the test bundle's `Fixtures` directory.
    static func data(_ name: String) throws -> Data {
        let candidates = [
            Bundle.module.url(forResource: name, withExtension: "json"),
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
        ]
        guard let url = candidates.compactMap({ $0 }).first else {
            throw FixtureError.notFound(name)
        }
        return try Data(contentsOf: url)
    }

    enum FixtureError: Error, CustomStringConvertible {
        case notFound(String)
        var description: String {
            switch self {
            case .notFound(let name): return "Fixture '\(name).json' not found in test bundle"
            }
        }
    }

    /// A `ServiceContext` wired to a `MockTransport`, for client tests.
    static func context(
        transport: MockTransport,
        baseURL: String = "http://localhost:8080",
        credential: String = "test-key"
    ) -> ServiceContext {
        ServiceContext(
            endpoint: InstanceEndpoint(baseURL: URL(string: baseURL)!),
            credential: credential,
            transport: transport
        )
    }
}

extension URLRequest {
    /// Convenience for asserting on a request's query parameter (e.g. SABnzbd `mode`).
    func queryValue(_ name: String) -> String? {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        return components.queryItems?.first(where: { $0.name == name })?.value
    }
}
