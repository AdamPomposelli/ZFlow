import Foundation

enum UsageStatisticsCoreTests {
    static func run() {
        punctuationIsNotAWord()
        anEmptyRunIsNotUse()
        wordsAreAttributedToTheApp()
        paceNeedsAMinuteOfSpeechToMeanAnything()
        anAbsurdDurationIsNotCounted()
        aStreakSurvivesTheMorningBeforeYouDictate()
        aGapEndsTheStreak()
        longestStreakSpansTheWholeRecord()
        oldDaysArePruned()
        audioIsSplitByWhereItWasProcessed()
        meetingAudioAddsMinutesButNotWords()
    }

    private static func day(_ text: String) -> Date {
        UsageStatisticsCore.dayFormatter.date(from: text)!
    }

    private static func punctuationIsNotAWord() {
        TestSupport.expectEqual(UsageStatisticsCore.wordCount(of: "Hello , world — again"), 3)
        TestSupport.expectEqual(UsageStatisticsCore.wordCount(of: "   "), 0)
        TestSupport.expectEqual(UsageStatisticsCore.wordCount(of: "Ça va, Aïcha ?"), 3)
    }

    /// A dictation that heard nothing is not use, and must not drag the pace
    /// down or extend a streak.
    private static func anEmptyRunIsNotUse() {
        let after = UsageStatisticsCore.recording(
            UsageStatistics(),
            transcript: "   ",
            speakingSeconds: 4,
            appName: "Mail",
            correctionsApplied: 0,
            onDevice: true,
            at: day("2026-09-28")
        )
        TestSupport.expectEqual(after, UsageStatistics())
    }

    private static func wordsAreAttributedToTheApp() {
        var stats = UsageStatistics()
        stats = UsageStatisticsCore.recording(stats, transcript: "one two three", speakingSeconds: 3, appName: "Mail", correctionsApplied: 1, onDevice: true, at: day("2026-09-28"))
        stats = UsageStatisticsCore.recording(stats, transcript: "four five", speakingSeconds: 2, appName: "Mail", correctionsApplied: 0, onDevice: true, at: day("2026-09-28"))
        stats = UsageStatisticsCore.recording(stats, transcript: "six", speakingSeconds: 1, appName: "Safari", correctionsApplied: 0, onDevice: true, at: day("2026-09-28"))
        TestSupport.expectEqual(stats.totalWords, 6)
        TestSupport.expectEqual(stats.totalDictations, 3)
        TestSupport.expectEqual(stats.wordsByApp["Mail"], 5)
        TestSupport.expectEqual(stats.wordsByApp["Safari"], 1)
        TestSupport.expectEqual(stats.correctionsApplied, 1)
        TestSupport.expectEqual(stats.dictationsByDay["2026-09-28"], 3)
    }

    private static func paceNeedsAMinuteOfSpeechToMeanAnything() {
        var stats = UsageStatistics()
        stats = UsageStatisticsCore.recording(stats, transcript: "one two three", speakingSeconds: 10, appName: nil, correctionsApplied: 0, onDevice: true, at: day("2026-09-28"))
        TestSupport.expect(stats.wordsPerMinute == nil, "ten seconds is not a pace")

        stats.totalSpeakingSeconds = 120
        stats.totalWords = 240
        TestSupport.expectEqual(stats.wordsPerMinute, 120)
    }

    /// A session left open, or a clock that moved, must not poison the pace.
    private static func anAbsurdDurationIsNotCounted() {
        let stats = UsageStatisticsCore.recording(
            UsageStatistics(),
            transcript: "one two",
            speakingSeconds: 9_999,
            appName: nil,
            correctionsApplied: 0,
            onDevice: true,
            at: day("2026-09-28")
        )
        TestSupport.expectEqual(stats.totalWords, 2)
        TestSupport.expectEqual(stats.totalSpeakingSeconds, 0)
    }

    private static func aStreakSurvivesTheMorningBeforeYouDictate() {
        let days = ["2026-09-26": 2, "2026-09-27": 1]
        TestSupport.expectEqual(
            UsageStatisticsCore.currentStreak(days: days, today: day("2026-09-28")),
            2
        )
    }

    private static func aGapEndsTheStreak() {
        let days = ["2026-09-20": 1, "2026-09-27": 1, "2026-09-28": 3]
        TestSupport.expectEqual(
            UsageStatisticsCore.currentStreak(days: days, today: day("2026-09-28")),
            2
        )
        TestSupport.expectEqual(
            UsageStatisticsCore.currentStreak(days: ["2026-09-20": 1], today: day("2026-09-28")),
            0
        )
    }

    private static func longestStreakSpansTheWholeRecord() {
        let days = ["2026-09-01": 1, "2026-09-02": 1, "2026-09-03": 1, "2026-09-10": 1, "2026-09-28": 1]
        TestSupport.expectEqual(UsageStatisticsCore.longestStreak(days: days), 3)
        TestSupport.expectEqual(UsageStatisticsCore.longestStreak(days: [:]), 0)
    }

    private static func oldDaysArePruned() {
        var stats = UsageStatistics()
        for index in 0..<10 {
            stats.dictationsByDay[String(format: "2026-01-%02d", index + 1)] = 1
        }
        let pruned = UsageStatisticsCore.pruned(stats, keepingDays: 4)
        TestSupport.expectEqual(pruned.dictationsByDay.count, 4)
        TestSupport.expect(pruned.dictationsByDay["2026-01-10"] == 1, "the newest day is kept")
        TestSupport.expect(pruned.dictationsByDay["2026-01-01"] == nil, "the oldest day is dropped")
    }
}

extension UsageStatisticsCoreTests {
    /// Only the on-device half can be called money not spent.
    static func audioIsSplitByWhereItWasProcessed() {
        var stats = UsageStatistics()
        stats = UsageStatisticsCore.recording(
            stats, transcript: "one two three", speakingSeconds: 30,
            appName: nil, correctionsApplied: 0, onDevice: true,
            at: UsageStatisticsCore.dayFormatter.date(from: "2026-09-28")!
        )
        stats = UsageStatisticsCore.recording(
            stats, transcript: "four five six", speakingSeconds: 20,
            appName: nil, correctionsApplied: 0, onDevice: false,
            at: UsageStatisticsCore.dayFormatter.date(from: "2026-09-28")!
        )
        TestSupport.expectEqual(stats.localAudioSeconds, 30)
        TestSupport.expectEqual(stats.cloudAudioSeconds, 20)
        TestSupport.expectEqual(stats.totalSpeakingSeconds, 50)
    }

    /// A recorded meeting is not a dictation: it adds no words you would have
    /// typed, and none of your own speaking time.
    static func meetingAudioAddsMinutesButNotWords() {
        let stats = UsageStatisticsCore.recordingMeetingAudio(
            UsageStatistics(), seconds: 1800, onDevice: true
        )
        TestSupport.expectEqual(stats.localAudioSeconds, 1800)
        TestSupport.expectEqual(stats.totalWords, 0)
        TestSupport.expectEqual(stats.totalSpeakingSeconds, 0)
        TestSupport.expectEqual(stats.totalDictations, 0)
    }
}
