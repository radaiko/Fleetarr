import Foundation

/// A decoded HTTP response, stripped down to what service clients need and made `Sendable`.
public struct HTTPResponse: Sendable, Equatable {
    public let status: Int
    public let data: Data
    /// Response headers with lowercased names.
    public let headers: [String: String]

    public init(status: Int, data: Data, headers: [String: String] = [:]) {
        self.status = status
        self.data = data
        self.headers = headers
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }
    public var isSuccess: Bool { (200..<300).contains(status) }
}

/// The seam between service clients and the network (spec §9.8: clients are unit-tested against
/// recorded/mocked responses). Production uses ``URLSessionTransport``; tests inject a mock.
public protocol HTTPTransport: Sendable {
    /// Sends a request, normalizing every failure into a ``FleetError``.
    func send(_ request: URLRequest) async throws(FleetError) -> HTTPResponse
}
