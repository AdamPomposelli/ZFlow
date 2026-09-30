import Foundation

enum ToastCountdownCoreTests {
    static func run() {
        testCountdownDepletesOverItsDuration()
        testHoverPausesAndRestoresTheFullWindow()
        testFractionStaysInRange()
        testInvalidDurationDoesNotExpireImmediately()
    }

    private static func testCountdownDepletesOverItsDuration() {
        var countdown = ToastCountdown(duration: 10)
        TestSupport.expectEqual(countdown.fractionRemaining, 1)
        TestSupport.expect(!countdown.isExpired, "A fresh countdown should not be expired")

        countdown.advance(by: 5)
        TestSupport.expectApproximatelyEqual(countdown.fractionRemaining, 0.5)
        TestSupport.expect(!countdown.isExpired, "Half elapsed should not be expired")

        countdown.advance(by: 5)
        TestSupport.expectEqual(countdown.fractionRemaining, 0)
        TestSupport.expect(countdown.isExpired, "The full duration should expire the toast")

        // Never runs negative, however many extra ticks arrive.
        countdown.advance(by: 100)
        TestSupport.expectEqual(countdown.remaining, 0)
        TestSupport.expectEqual(countdown.fractionRemaining, 0)
    }

    private static func testHoverPausesAndRestoresTheFullWindow() {
        var countdown = ToastCountdown(duration: 10)
        countdown.advance(by: 9)
        TestSupport.expect(!countdown.isExpired, "One second should still be left")

        // Pointer arrives with the toast nearly gone: it must stop draining, or
        // the Retry button disappears as the user reaches for it.
        countdown.isPaused = true
        countdown.advance(by: 60)
        TestSupport.expect(!countdown.isExpired, "A hovered toast must not expire")
        TestSupport.expectApproximatelyEqual(countdown.remaining, 1)

        // Pointer leaves: the whole window comes back rather than the sliver
        // that was left on arrival.
        countdown.isPaused = false
        countdown.reset()
        TestSupport.expectEqual(countdown.fractionRemaining, 1)

        countdown.advance(by: 10)
        TestSupport.expect(countdown.isExpired, "It should expire normally after the pointer leaves")
    }

    private static func testFractionStaysInRange() {
        var countdown = ToastCountdown(duration: 4)
        for _ in 0..<200 {
            countdown.advance(by: 1.0 / 30.0)
            TestSupport.expect(
                countdown.fractionRemaining >= 0 && countdown.fractionRemaining <= 1,
                "The bar's fill must stay within its track"
            )
        }
        TestSupport.expect(countdown.isExpired, "Ticking well past the duration should expire it")
    }

    private static func testInvalidDurationDoesNotExpireImmediately() {
        // A zero or negative duration would otherwise divide by zero and make a
        // toast vanish on its first frame.
        for duration in [0.0, -5.0] {
            var countdown = ToastCountdown(duration: duration)
            TestSupport.expect(countdown.duration > 0, "Duration should be clamped to something positive")
            TestSupport.expect(!countdown.isExpired, "A clamped toast should still be shown")
            TestSupport.expectEqual(countdown.fractionRemaining, 1)
            countdown.advance(by: countdown.duration)
            TestSupport.expect(countdown.isExpired, "It should still expire after its clamped duration")
        }
    }
}
