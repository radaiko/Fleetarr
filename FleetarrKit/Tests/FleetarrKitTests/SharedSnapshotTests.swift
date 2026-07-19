import Foundation
import Testing
@testable import FleetarrKit

@Suite("Shared snapshot (spec §9.7)")
struct SharedSnapshotTests {
    @Test("FleetSnapshot round-trips through Codable and resolves its enums")
    func roundTrip() throws {
        let snapshot = FleetSnapshot(
            problemBadgeCount: 3,
            worstHealth: .error,
            unreachableCount: 1,
            instances: [
                InstanceSnapshot(
                    id: UUID(),
                    label: "Sonarr",
                    serviceType: .sonarr,
                    health: .warning,
                    summaryLine: "2 in queue"
                )
            ],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(FleetSnapshot.self, from: data)

        #expect(decoded == snapshot)
        #expect(decoded.worstHealth == .error)
        #expect(decoded.instances.first?.serviceType == .sonarr)
        #expect(decoded.instances.first?.health == .warning)
    }
}
