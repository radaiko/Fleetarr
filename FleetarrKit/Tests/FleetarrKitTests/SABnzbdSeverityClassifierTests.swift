import Testing
@testable import FleetarrKit

@Suite("SABnzbd severity classification (spec §6.4)")
struct SABnzbdSeverityClassifierTests {
    @Test("A clean, in-progress item is not a problem")
    func downloadingIsNotAProblem() {
        #expect(SABnzbdSeverityClassifier.classify(status: "Downloading") == nil)
        #expect(SABnzbdSeverityClassifier.classify(status: "Queued") == nil)
        #expect(SABnzbdSeverityClassifier.classify(status: "Completed", failMessage: "") == nil)
    }

    @Test("A failed download is an error")
    func failedIsError() {
        #expect(SABnzbdSeverityClassifier.classify(status: "Failed") == .error)
    }

    @Test("A failed unpack / disk-full message is an error")
    func unpackFailureIsError() {
        let severity = SABnzbdSeverityClassifier.classify(
            status: "Failed",
            failMessage: "Unpacking failed, write error or disk is full?"
        )
        #expect(severity == .error)
    }

    @Test("A paused item is a warning")
    func pausedIsWarning() {
        #expect(SABnzbdSeverityClassifier.classify(status: "Paused") == .warning)
    }

    @Test("The confirmed-benign non-writable filename warning is cosmetic, not counted")
    func knownBenignIsCosmetic() {
        let severity = SABnzbdSeverityClassifier.classify(
            status: "Failed",
            failMessage: "Cannot create non-writable special-character filename, skipping"
        )
        #expect(severity == .cosmetic)
        // Cosmetic problems must not count toward the badge (spec §6.4).
        let problem = Problem(severity: severity!, title: "x")
        #expect(problem.countsTowardBadge == false)
    }

    @Test("A user-supplied ignore pattern downgrades a matching warning to cosmetic")
    func userIgnorePatternIsRespected() {
        let normal = SABnzbdSeverityClassifier.classify(
            status: "Failed",
            failMessage: "Repair failed, too many bad articles"
        )
        #expect(normal == .error)

        let ignored = SABnzbdSeverityClassifier.classify(
            status: "Failed",
            failMessage: "Repair failed, too many bad articles",
            ignorePatterns: ["too many bad articles"]
        )
        #expect(ignored == .cosmetic)
    }
}
