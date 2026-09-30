import Foundation

enum EditSettleTrackerTests {
    static func run() {
        testNothingIsReportedWhileTyping()
        testSettlesOnceTypingStops()
        testSecondRoundComparesAgainstWhatWasReported()
        testWindowExpiryStillReportsAnUnsettledEdit()
    }

    private static func tracker(baseline: String, at start: Date) -> EditSettleTracker {
        EditSettleTracker(baseline: baseline, startedAt: start, settleDelay: 2, maximumWatch: 45)
    }

    /// The reason this exists: while "Hoaven" becomes "Hoop Haven" the field
    /// passes through "Hoop", "Hoop H", "Hoop Hav". Comparing against any of
    /// those would learn a wrong rule.
    private static func testNothingIsReportedWhileTyping() {
        let start = Date(timeIntervalSince1970: 0)
        var subject = tracker(baseline: "marque Hoaven que", at: start)

        var now = start
        for partial in ["marque Hoop que", "marque Hoop H que", "marque Hoop Hav que"] {
            now = now.addingTimeInterval(0.4)
            TestSupport.expectEqual(subject.observe(partial, at: now), .waiting)
            // Still within the settle delay of the previous keystroke.
            now = now.addingTimeInterval(0.4)
            TestSupport.expectEqual(subject.observe(partial, at: now), .waiting)
        }
    }

    private static func testSettlesOnceTypingStops() {
        let start = Date(timeIntervalSince1970: 0)
        var subject = tracker(baseline: "marque Hoaven que", at: start)

        // Unchanged polls report nothing at all.
        TestSupport.expectEqual(subject.observe("marque Hoaven que", at: start.addingTimeInterval(1)), .waiting)

        let typed = start.addingTimeInterval(2)
        TestSupport.expectEqual(subject.observe("marque Hoop Haven que", at: typed), .waiting)
        // Not yet: the delay has not elapsed.
        TestSupport.expectEqual(
            subject.observe("marque Hoop Haven que", at: typed.addingTimeInterval(1.5)),
            .waiting
        )
        TestSupport.expectEqual(
            subject.observe("marque Hoop Haven que", at: typed.addingTimeInterval(2.0)),
            .settled("marque Hoop Haven que")
        )
        // Reported once, not on every later poll.
        TestSupport.expectEqual(
            subject.observe("marque Hoop Haven que", at: typed.addingTimeInterval(3.0)),
            .waiting
        )
    }

    private static func testSecondRoundComparesAgainstWhatWasReported() {
        let start = Date(timeIntervalSince1970: 0)
        var subject = tracker(baseline: "a b c", at: start)

        let first = start.addingTimeInterval(1)
        _ = subject.observe("a X c", at: first)
        TestSupport.expectEqual(subject.observe("a X c", at: first.addingTimeInterval(2)), .settled("a X c"))
        subject.acceptAsBaseline("a X c")

        // The same text is no longer an edit.
        TestSupport.expectEqual(subject.observe("a X c", at: first.addingTimeInterval(5)), .waiting)

        // A further edit settles on its own.
        let second = first.addingTimeInterval(6)
        _ = subject.observe("a X Y", at: second)
        TestSupport.expectEqual(subject.observe("a X Y", at: second.addingTimeInterval(2)), .settled("a X Y"))
    }

    private static func testWindowExpiryStillReportsAnUnsettledEdit() {
        let start = Date(timeIntervalSince1970: 0)
        var subject = tracker(baseline: "a b c", at: start)

        // Typing right up to the deadline: the edit is still examined rather
        // than thrown away.
        _ = subject.observe("a b c d", at: start.addingTimeInterval(44.8))
        TestSupport.expectEqual(
            subject.observe("a b c d", at: start.addingTimeInterval(45)),
            .expired("a b c d")
        )

        // With no edit at all there is nothing to report.
        var untouched = tracker(baseline: "a b c", at: start)
        TestSupport.expectEqual(
            untouched.observe("a b c", at: start.addingTimeInterval(45)),
            .expired(nil)
        )
    }
}
