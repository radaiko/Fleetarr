import Foundation
import Testing
@testable import FleetarrKit

@Suite("Concurrent fleet refresh (spec §3.2, §9.2)")
struct FleetRefresherTests {
    private func sabClient(transport: MockTransport) -> SABnzbdClient {
        SABnzbdClient(context: Fixture.context(transport: transport))
    }

    @Test("One unreachable instance does not block the others")
    func failureIsIsolated() async throws {
        let queue = try Fixture.data("sabnzbd_queue")
        let history = try Fixture.data("sabnzbd_history")

        let healthy = sabClient(transport: MockTransport { request in
            switch request.queryValue("mode") {
            case "history": return .response(status: 200, data: history)
            default: return .response(status: 200, data: queue)
            }
        })
        let broken = sabClient(transport: MockTransport(error: .timedOut))

        let healthyID = UUID()
        let brokenID = UUID()
        let results = await FleetRefresher.refresh(services: [
            (healthyID, healthy),
            (brokenID, broken),
        ])

        #expect(results.count == 2)
        #expect(results[brokenID]?.health == .unreachable)
        // The healthy instance still produced a real status despite the sibling failing.
        #expect(results[healthyID]?.health == .error) // fixture has a genuine failed item
        #expect(results[healthyID]?.serviceVersion == "4.3.2")
    }

    @Test("An enabled instance with no credential is reported as not-configured")
    func missingCredentialIsUnknown() async {
        let instance = FleetInstance(
            serviceType: .sabnzbd,
            label: "SAB",
            baseURLString: "http://localhost:8080"
        )
        let results = await FleetRefresher.refresh(
            instances: [instance],
            factory: DefaultFleetServiceFactory(),
            credential: { _ in nil }
        )
        #expect(results[instance.id]?.health == .unknown)
    }

    @Test("FleetSummary aggregates badge count and worst health (spec §5)")
    func summaryAggregates() {
        let statuses: [InstanceStatus] = [
            InstanceStatus(health: .healthy),
            InstanceStatus(health: .warning, problems: [Problem(severity: .warning, title: "w")]),
            InstanceStatus(health: .unreachable, problems: [Problem(severity: .error, title: "down")]),
            // A cosmetic-only status contributes nothing to the badge (spec §6.4).
            InstanceStatus(health: .healthy, problems: [Problem(severity: .cosmetic, title: "noise")]),
        ]
        let summary = FleetSummary(statuses: statuses)
        #expect(summary.problemBadgeCount == 2)
        #expect(summary.worstHealth == .unreachable)
        #expect(summary.unreachableCount == 1)
    }
}
