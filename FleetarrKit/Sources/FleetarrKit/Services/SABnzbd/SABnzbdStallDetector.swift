import Foundation

/// Detects **stalled** SABnzbd downloads — an active item whose progress hasn't advanced for longer
/// than a configurable threshold (spec §6.4). This is inherently temporal, so it can't be judged
/// from a single snapshot: the caller carries a ``State`` across refreshes and feeds each new set of
/// samples through ``advance(_:samples:now:threshold:)``, which returns the ids now considered
/// stalled plus the updated state to keep. Pure and deterministic (time is injected) so it's unit
/// testable without a transport or a real clock (spec §9.8).
public enum SABnzbdStallDetector {
    /// One active-queue item's progress at a moment in time.
    public struct Sample: Sendable, Equatable {
        public let id: String
        /// Download progress, 0–100.
        public let percentage: Double
        /// Whether the item is actively downloading (not paused, not a fetch/queued placeholder) —
        /// only active items can "stall".
        public let isActive: Bool

        public init(id: String, percentage: Double, isActive: Bool) {
            self.id = id
            self.percentage = percentage
            self.isActive = isActive
        }
    }

    /// The memory carried between refreshes: for each item, the last-seen percentage and the time it
    /// was first observed *at that percentage* (the clock that a stall is measured against).
    public struct State: Sendable, Equatable {
        struct Entry: Sendable, Equatable {
            var percentage: Double
            var since: Date
        }
        var entries: [String: Entry]
        public init() { entries = [:] }
    }

    /// Advances the state with the latest samples.
    ///
    /// - An item whose percentage is unchanged from last time keeps its original `since`; if it's
    ///   active and has held that percentage for at least `threshold`, it's reported stalled.
    /// - An item that's new, or whose percentage moved, resets its clock to `now`.
    /// - Items absent from `samples` (finished/removed) are dropped from the state.
    public static func advance(
        _ state: State,
        samples: [Sample],
        now: Date,
        threshold: TimeInterval
    ) -> (stalled: Set<String>, state: State) {
        var next = State()
        var stalled: Set<String> = []
        for sample in samples {
            if let prior = state.entries[sample.id], prior.percentage == sample.percentage {
                next.entries[sample.id] = prior
                if sample.isActive, now.timeIntervalSince(prior.since) >= threshold {
                    stalled.insert(sample.id)
                }
            } else {
                next.entries[sample.id] = .init(percentage: sample.percentage, since: now)
            }
        }
        return (stalled, next)
    }
}
