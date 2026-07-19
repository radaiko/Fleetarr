import Foundation

/// Everything a service client needs to make one authenticated call to one instance: the
/// endpoint config, the secret credential, and the transport. Clients are built with a
/// ``ServiceContext`` so they can be unit-tested by injecting a mock transport (spec §9.8).
///
/// The credential is held only in memory here and is **never** logged (spec §4).
public struct ServiceContext: Sendable {
    public var endpoint: InstanceEndpoint
    public var credential: String
    public var transport: any HTTPTransport

    public init(endpoint: InstanceEndpoint, credential: String, transport: any HTTPTransport) {
        self.endpoint = endpoint
        self.credential = credential
        self.transport = transport
    }

    /// Production convenience: builds a context with a real `URLSession` transport.
    public init(instance: FleetInstance, credential: String, timeout: TimeInterval = 15) throws(FleetError) {
        guard let endpoint = InstanceEndpoint(instance: instance, timeout: timeout) else {
            throw FleetError.invalidURL
        }
        self.init(
            endpoint: endpoint,
            credential: credential,
            transport: URLSessionTransport(endpoint: endpoint)
        )
    }
}

public extension ServiceContext {
    /// Joins the instance's base URL (which may include a reverse-proxy path prefix such as
    /// `/sonarr`) with an API path and query items (spec §9.4).
    func makeURL(path: String, query: [URLQueryItem] = []) -> URL? {
        guard var components = URLComponents(url: endpoint.baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var basePath = components.path
        if basePath.hasSuffix("/") { basePath.removeLast() }
        let suffix = path.hasPrefix("/") ? path : "/" + path
        components.path = basePath + suffix
        if !query.isEmpty {
            components.queryItems = (components.queryItems ?? []) + query
        }
        return components.url
    }

    /// Builds a request, applying the instance's static extra headers plus any per-call headers.
    /// Per-call headers win on conflict. Auth is applied by the caller (each service differs).
    func makeRequest(
        path: String,
        method: String = "GET",
        query: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: Data? = nil
    ) throws(FleetError) -> URLRequest {
        guard let url = makeURL(path: path, query: query) else { throw FleetError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = endpoint.timeout
        for (key, value) in endpoint.extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = body
        return request
    }

    /// Sends a request and validates the status code, mapping 401/403/404/5xx into ``FleetError``.
    func send(_ request: URLRequest) async throws(FleetError) -> HTTPResponse {
        let response = try await transport.send(request)
        return try Self.validate(response)
    }

    /// Sends a request and decodes the JSON body into `T`.
    func fetchJSON<T: Decodable>(
        _ type: T.Type = T.self,
        path: String,
        method: String = "GET",
        query: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: Data? = nil,
        decoder: JSONDecoder = ServiceContext.defaultDecoder
    ) async throws(FleetError) -> T {
        let request = try makeRequest(path: path, method: method, query: query, headers: headers, body: body)
        let response = try await send(request)
        return try Self.decode(type, from: response.data, decoder: decoder)
    }

    static func validate(_ response: HTTPResponse) throws(FleetError) -> HTTPResponse {
        switch response.status {
        case 200..<300:
            return response
        case 401, 403:
            throw FleetError.unauthorized
        case 404:
            throw FleetError.notFound
        default:
            throw FleetError.serverError(status: response.status)
        }
    }

    static func decode<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        decoder: JSONDecoder = ServiceContext.defaultDecoder
    ) throws(FleetError) -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw FleetError.decoding(String(describing: type))
        }
    }

    /// A lenient decoder for the *arr / media APIs. Individual clients may supply their own.
    static var defaultDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
