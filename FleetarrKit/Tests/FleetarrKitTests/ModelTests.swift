import Foundation
import Testing
@testable import FleetarrKit

@Suite("Domain models")
struct ModelTests {
    @Test("Health states order by severity, worst wins")
    func healthOrdering() {
        #expect(HealthState.unknown < HealthState.healthy)
        #expect(HealthState.warning < HealthState.error)
        #expect(HealthState.error < HealthState.unreachable)
        let worst = [HealthState.healthy, .warning, .unreachable, .error].max()
        #expect(worst == .unreachable)
    }

    @Test("Badge count excludes cosmetic problems (spec §6.4)")
    func badgeCountExcludesCosmetic() {
        let problems = [
            Problem(severity: .error, title: "a"),
            Problem(severity: .warning, title: "b"),
            Problem(severity: .cosmetic, title: "c"),
        ]
        #expect(problems.badgeCount == 2)
        #expect(problems.worstBadgeSeverity == .error)
    }

    @Test("A cosmetic-only problem set has no badge severity")
    func cosmeticOnlyHasNoBadgeSeverity() {
        let problems = [Problem(severity: .cosmetic, title: "noise")]
        #expect(problems.badgeCount == 0)
        #expect(problems.worstBadgeSeverity == nil)
    }

    @Test("FleetInstance parses base URL and flags plain HTTP")
    func instanceURLParsing() {
        let secure = FleetInstance(serviceType: .sonarr, label: "S", baseURLString: "https://host/sonarr")
        #expect(secure.baseURL != nil)
        #expect(secure.usesPlainHTTP == false)

        let insecure = FleetInstance(serviceType: .sonarr, label: "S", baseURLString: "http://10.0.0.2:8989")
        #expect(insecure.usesPlainHTTP)

        let invalid = FleetInstance(serviceType: .sonarr, label: "S", baseURLString: "not a url")
        #expect(invalid.baseURL == nil)
    }

    @Test("Service types expose credential kind and display metadata")
    func serviceTypeMetadata() {
        #expect(ServiceType.plex.credentialKind == .plexOAuthToken)
        #expect(ServiceType.sonarr.credentialKind == .apiKey)
        #expect(ServiceType.allCases.count == 7)
        #expect(!ServiceType.sabnzbd.displayName.isEmpty)
    }
}
