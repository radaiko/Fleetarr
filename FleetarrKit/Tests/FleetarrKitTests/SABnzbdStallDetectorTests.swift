import Foundation
import Testing
@testable import FleetarrKit

@Suite("SABnzbd stall detector (spec §6.4)")
struct SABnzbdStallDetectorTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let threshold: TimeInterval = 600 // 10 minutes

    @Test("An active item that hasn't progressed past the threshold is stalled")
    func stalledWhenUnchangedPastThreshold() {
        let sample = [SABnzbdStallDetector.Sample(id: "a", percentage: 40, isActive: true)]
        let first = SABnzbdStallDetector.advance(.init(), samples: sample, now: t0, threshold: threshold)
        #expect(first.stalled.isEmpty) // clock only just started

        let later = SABnzbdStallDetector.advance(
            first.state, samples: sample, now: t0.addingTimeInterval(660), threshold: threshold
        )
        #expect(later.stalled == ["a"])
    }

    @Test("Progress resets the stall clock")
    func progressResetsTheClock() {
        let first = SABnzbdStallDetector.advance(
            .init(), samples: [.init(id: "a", percentage: 40, isActive: true)], now: t0, threshold: threshold
        )
        // 11 minutes later but progressed → not stalled, clock reset.
        let second = SABnzbdStallDetector.advance(
            first.state, samples: [.init(id: "a", percentage: 55, isActive: true)],
            now: t0.addingTimeInterval(660), threshold: threshold
        )
        #expect(second.stalled.isEmpty)
        // A further 11 minutes at the same 55% → now stalled.
        let third = SABnzbdStallDetector.advance(
            second.state, samples: [.init(id: "a", percentage: 55, isActive: true)],
            now: t0.addingTimeInterval(1320), threshold: threshold
        )
        #expect(third.stalled == ["a"])
    }

    @Test("A paused / inactive item is never reported stalled")
    func inactiveIsNeverStalled() {
        let sample = [SABnzbdStallDetector.Sample(id: "a", percentage: 40, isActive: false)]
        let first = SABnzbdStallDetector.advance(.init(), samples: sample, now: t0, threshold: threshold)
        let later = SABnzbdStallDetector.advance(
            first.state, samples: sample, now: t0.addingTimeInterval(660), threshold: threshold
        )
        #expect(later.stalled.isEmpty)
    }

    @Test("Finished / removed items are dropped from the carried state")
    func removedItemsAreDropped() {
        let first = SABnzbdStallDetector.advance(
            .init(), samples: [.init(id: "a", percentage: 40, isActive: true)], now: t0, threshold: threshold
        )
        let second = SABnzbdStallDetector.advance(
            first.state, samples: [], now: t0.addingTimeInterval(660), threshold: threshold
        )
        #expect(second.state.entries.isEmpty)
        #expect(second.stalled.isEmpty)
    }
}
