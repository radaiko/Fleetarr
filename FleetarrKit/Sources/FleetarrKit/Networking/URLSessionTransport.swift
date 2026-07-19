import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A `URLSession`-backed ``HTTPTransport`` with per-instance TLS trust handling and timeouts.
public final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession

    public init(endpoint: InstanceEndpoint) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = endpoint.timeout
        config.timeoutIntervalForResource = endpoint.timeout
        // Fail fast rather than waiting for connectivity — an unreachable instance must not block
        // the rest of the dashboard (spec §3.2, §9.1).
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData

        let delegate = TLSTrustDelegate(
            allowInsecureTLS: endpoint.allowInsecureTLS,
            host: endpoint.baseURL.host
        )
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    /// Testing / advanced init with a caller-provided session.
    public init(session: URLSession) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws(FleetError) -> HTTPResponse {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw FleetError.transport("non-HTTP response")
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let keyString = key as? String, let valueString = value as? String {
                    headers[keyString.lowercased()] = valueString
                }
            }
            return HTTPResponse(status: http.statusCode, data: data, headers: headers)
        } catch let urlError as URLError {
            throw FleetError.from(urlError: urlError)
        } catch let fleetError as FleetError {
            throw fleetError
        } catch {
            throw FleetError.transport("unexpected transport failure")
        }
    }
}

/// Accepts self-signed / private-CA server certificates, but **only** for the instance's own host,
/// so a trust override never leaks to unrelated hosts (spec §9.3: scope exceptions per instance).
private final class TLSTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let allowInsecureTLS: Bool
    private let host: String?

    init(allowInsecureTLS: Bool, host: String?) {
        self.allowInsecureTLS = allowInsecureTLS
        self.host = host
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard allowInsecureTLS,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        // Only override trust for the instance's configured host.
        if let host, challenge.protectionSpace.host != host {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }
}
