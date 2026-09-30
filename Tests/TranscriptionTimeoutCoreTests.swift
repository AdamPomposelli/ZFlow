import Foundation

enum TranscriptionTimeoutCoreTests {
    static func run() {
        testBudgetScalesWithRecordingLength()
        testBudgetHandlesMissingAndInvalidDuration()
        testBudgetIsCapped()
        testShortMessageNamesProviderAndAudio()
        testDetailedMessageAnswersWhatTimedOut()
        testDetailedMessageDegradesWithoutMeasurements()
    }

    private static func testBudgetScalesWithRecordingLength() {
        let base = TranscriptionTimeoutBudget.defaultBaseSeconds

        // The failure that motivated this: a 24s recording against a fixed 20s
        // budget. The budget must now exceed the recording by a clear margin.
        let twentyFour = TranscriptionTimeoutBudget.seconds(
            baseSeconds: base,
            audioDurationSeconds: 24
        )
        TestSupport.expect(twentyFour > 24, "A 24s recording should get more than 24s of budget")
        TestSupport.expectApproximatelyEqual(twentyFour, base + 24 * TranscriptionTimeoutBudget.perAudioSecond)

        // Longer recordings get proportionally more.
        let sixty = TranscriptionTimeoutBudget.seconds(baseSeconds: base, audioDurationSeconds: 60)
        TestSupport.expect(sixty > twentyFour, "A longer recording should get a larger budget")

        // A short clip still gets the full base budget; scaling only ever adds.
        let short = TranscriptionTimeoutBudget.seconds(baseSeconds: base, audioDurationSeconds: 2)
        TestSupport.expect(short >= base, "Scaling must never reduce the base budget")

        // An explicit user override is the base, and still scales.
        let overridden = TranscriptionTimeoutBudget.seconds(baseSeconds: 120, audioDurationSeconds: 24)
        TestSupport.expect(overridden > 120, "A user override should still scale with the recording")
    }

    private static func testBudgetHandlesMissingAndInvalidDuration() {
        let base = TranscriptionTimeoutBudget.defaultBaseSeconds
        // An unreadable audio header must not shrink the budget to zero.
        TestSupport.expectEqual(
            TranscriptionTimeoutBudget.seconds(baseSeconds: base, audioDurationSeconds: nil),
            base
        )
        TestSupport.expectEqual(
            TranscriptionTimeoutBudget.seconds(baseSeconds: base, audioDurationSeconds: 0),
            base
        )
        TestSupport.expectEqual(
            TranscriptionTimeoutBudget.seconds(baseSeconds: base, audioDurationSeconds: -5),
            base
        )
        // A missing or nonsensical override falls back to the default base.
        TestSupport.expectEqual(
            TranscriptionTimeoutBudget.seconds(baseSeconds: 0, audioDurationSeconds: nil),
            base
        )
    }

    private static func testBudgetIsCapped() {
        // A very long recording must still fail in bounded time.
        let huge = TranscriptionTimeoutBudget.seconds(
            baseSeconds: TranscriptionTimeoutBudget.defaultBaseSeconds,
            audioDurationSeconds: 100_000
        )
        TestSupport.expectEqual(huge, TranscriptionTimeoutBudget.maximumSeconds)
    }

    private static func report(
        timeout: TimeInterval = 38,
        duration: TimeInterval? = 24,
        bytes: Int64? = 1_032_192,
        host: String? = "zenmux.ai"
    ) -> TranscriptionTimeoutReport {
        TranscriptionTimeoutReport(
            timeoutSeconds: timeout,
            audioDurationSeconds: duration,
            uploadByteCount: bytes,
            host: host,
            usesJSONBase64: true,
            model: "qwen/qwen3-asr-flash",
            defaultsDomain: "com.example.zflow.test"
        )
    }

    private static func testShortMessageNamesProviderAndAudio() {
        let message = report().shortMessage
        TestSupport.expect(message.contains("zenmux.ai"), "Short message should name the provider")
        TestSupport.expect(message.contains("38s"), "Short message should state the limit")
        TestSupport.expect(message.contains("24s"), "Short message should state the audio length")

        // Without a measurement it still has to read as a sentence.
        let noDuration = report(duration: nil, bytes: nil).shortMessage
        TestSupport.expect(noDuration.contains("zenmux.ai"), "Short message should still name the provider")
        TestSupport.expect(!noDuration.contains("of audio"), "Short message should not claim an unknown duration")
    }

    private static func testDetailedMessageAnswersWhatTimedOut() {
        let message = report().detailedMessage

        // How long it waited, and that the wait was ZFlow's, not a provider error.
        TestSupport.expect(message.contains("38s"), "Should state the limit that was hit")
        TestSupport.expect(
            message.lowercased().contains("not an error from the provider"),
            "Should distinguish giving up from a provider-reported failure"
        )
        // What was sent.
        TestSupport.expect(message.contains("qwen/qwen3-asr-flash"), "Should name the model")
        TestSupport.expect(message.contains("24s of audio"), "Should state how much audio was sent")
        TestSupport.expect(
            message.contains("KB") || message.contains("MB"),
            "Should state the payload size"
        )

        // Megabyte-scale payloads read in MB rather than four-digit KB.
        let large = report(bytes: 4_194_304).detailedMessage
        TestSupport.expect(large.contains("4.0 MB"), "A multi-megabyte payload should be shown in MB")
        TestSupport.expect(message.contains("base64"), "Should say the payload was base64 encoded")
        // What the user can change.
        TestSupport.expect(
            message.contains("transcription_timeout_seconds"),
            "Should name the setting that raises the limit"
        )
        TestSupport.expect(
            message.contains("com.example.zflow.test"),
            "Should use the running bundle's defaults domain"
        )
        // Several lines, since this is the Run Log entry.
        TestSupport.expect(
            message.components(separatedBy: "\n").count >= 4,
            "Detailed message should be more than a single line"
        )
    }

    private static func testDetailedMessageDegradesWithoutMeasurements() {
        let message = report(duration: nil, bytes: nil, host: nil).detailedMessage
        // No invented numbers when nothing could be measured.
        TestSupport.expect(!message.contains("of audio"), "Should not state an unknown duration")
        TestSupport.expect(!message.contains("MB"), "Should not state an unknown payload size")
        TestSupport.expect(!message.contains("KB"), "Should not state an unknown payload size")
        TestSupport.expect(message.contains("The provider"), "Should fall back to a generic provider name")
    }
}
