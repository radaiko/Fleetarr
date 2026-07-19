import Foundation

/// The outcome of a "Test Connection" action (spec §4): success carries the service version when
/// available; failure carries the *real* reason (DNS/TLS/401/timeout) rather than a generic error.
public enum ConnectionTestResult: Sendable, Equatable {
    case success(version: String?)
    case failure(FleetError)

    public var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    /// A user-facing description suitable for showing directly under the Test Connection button.
    public var message: String {
        switch self {
        case .success(let version):
            if let version, !version.isEmpty {
                return "Connected successfully (version \(version))."
            }
            return "Connected successfully."
        case .failure(let error):
            return error.userMessage
        }
    }
}
