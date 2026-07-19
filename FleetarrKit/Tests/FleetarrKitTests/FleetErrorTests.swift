import Foundation
import Testing
@testable import FleetarrKit

@Suite("FleetError classification (spec §4, §9.4)")
struct FleetErrorTests {
    @Test("URLError codes map to the right FleetError")
    func mapsURLErrors() {
        #expect(FleetError.from(urlError: URLError(.timedOut)) == .timedOut)
        #expect(FleetError.from(urlError: URLError(.cannotConnectToHost)) == .cannotConnect)
        #expect(FleetError.from(urlError: URLError(.cannotFindHost)) == .dnsFailure)
        #expect(FleetError.from(urlError: URLError(.dnsLookupFailed)) == .dnsFailure)
        #expect(FleetError.from(urlError: URLError(.notConnectedToInternet)) == .offline)
        #expect(FleetError.from(urlError: URLError(.cancelled)) == .cancelled)
        if case .tlsFailure = FleetError.from(urlError: URLError(.serverCertificateUntrusted)) {
            // ok
        } else {
            Issue.record("serverCertificateUntrusted should map to .tlsFailure")
        }
    }

    @Test("Reachability failures imply an unreachable health state")
    func reachabilityImpliesUnreachable() {
        #expect(FleetError.timedOut.impliedHealthState == .unreachable)
        #expect(FleetError.cannotConnect.impliedHealthState == .unreachable)
        #expect(FleetError.tlsFailure(nil).impliedHealthState == .unreachable)
        #expect(FleetError.dnsFailure.impliedHealthState == .unreachable)
    }

    @Test("Server-reported failures imply an error (reachable) state, not unreachable")
    func serverErrorsAreReachable() {
        #expect(FleetError.unauthorized.impliedHealthState == .error)
        #expect(FleetError.notFound.impliedHealthState == .error)
        #expect(FleetError.serverError(status: 500).impliedHealthState == .error)
        #expect(FleetError.unauthorized.isReachabilityFailure == false)
    }

    @Test("User messages never contain a URL or credential")
    func userMessagesAreSafe() {
        for error: FleetError in [.timedOut, .unauthorized, .tlsFailure("bad cert"), .notFound] {
            #expect(!error.userMessage.isEmpty)
        }
    }
}
