import Foundation

enum SavingsCoreTests {
    static func run() {
        onlyAudioKeptOnThisMacCounts()
        theRateIsTheOnePublished()
        typingTimeIsTheDifferenceNotTheWhole()
        dictatingSlowlyIsNotReportedAsALoss()
        tinyFiguresAreNotWorthShowing()
        durationsReadInTheLargestHonestUnit()
        moneyReadsAsMoney()
    }

    /// Audio sent to a provider was paid for. One provider's bill against
    /// another's is not a saving.
    private static func onlyAudioKeptOnThisMacCounts() {
        TestSupport.expectEqual(SavingsCore.moneyNotSpent(localSeconds: 0), 0)
        let hour = SavingsCore.moneyNotSpent(localSeconds: 3600)
        TestSupport.expectApproximatelyEqual(hour, 0.36, accuracy: 0.0001)
    }

    private static func theRateIsTheOnePublished() {
        TestSupport.expectEqual(SavingsCore.referenceTranscriptionCostPerMinute, 0.006)
        TestSupport.expectApproximatelyEqual(
            SavingsCore.moneyNotSpent(localSeconds: 600),
            0.06,
            accuracy: 0.0001
        )
    }

    private static func typingTimeIsTheDifferenceNotTheWhole() {
        // 400 words is 10 minutes typed at 40 wpm; saying them took 2.
        let saved = SavingsCore.minutesNotSpentTyping(words: 400, speakingSeconds: 120)
        TestSupport.expectApproximatelyEqual(saved, 8, accuracy: 0.001)
    }

    /// One word said slowly is not evidence that dictation is slower.
    private static func dictatingSlowlyIsNotReportedAsALoss() {
        TestSupport.expectEqual(
            SavingsCore.minutesNotSpentTyping(words: 1, speakingSeconds: 600),
            0
        )
        TestSupport.expectEqual(SavingsCore.minutesNotSpentTyping(words: 0, speakingSeconds: 0), 0)
    }

    /// Figures that read as noise invite distrust of the rest of the page.
    private static func tinyFiguresAreNotWorthShowing() {
        TestSupport.expect(
            !SavingsCore.isWorthShowing(minutesSaved: 0.4, moneySaved: 0.001),
            "a fraction of a cent is not a number"
        )
        TestSupport.expect(
            SavingsCore.isWorthShowing(minutesSaved: 1, moneySaved: 0),
            "a minute is worth saying"
        )
        TestSupport.expect(
            SavingsCore.isWorthShowing(minutesSaved: 0, moneySaved: 0.01),
            "a cent is worth saying"
        )
    }

    private static func durationsReadInTheLargestHonestUnit() {
        TestSupport.expectEqual(SavingsCore.readableDuration(minutes: 0.5), "under a minute")
        TestSupport.expectEqual(SavingsCore.readableDuration(minutes: 42), "42 min")
        TestSupport.expectEqual(SavingsCore.readableDuration(minutes: 120), "2 h")
        TestSupport.expectEqual(SavingsCore.readableDuration(minutes: 80), "1 h 20")
        TestSupport.expectEqual(SavingsCore.readableDuration(minutes: 60 * 24 * 3), "3.0 days")
    }

    private static func moneyReadsAsMoney() {
        TestSupport.expectEqual(SavingsCore.readableMoney(0.004), "$0.00")
        TestSupport.expectEqual(SavingsCore.readableMoney(2.5), "$2.50")
        TestSupport.expectEqual(SavingsCore.readableMoney(42.7), "$43")
    }
}
