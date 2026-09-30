import Foundation

enum TranscriptionErrorPresentationCoreTests {
    static func run() {
        testConnectionLostOffersRetryAndNetworkGuidance()
        testOfflineFailuresRemainClassifiedAsNoInternet()
        testTranscriptionStageFailuresAreRecognized()
        testSelfDescribingErrorsKeepTheirOwnMessage()
    }

    /// The Run Log renders a transcription failure under "Transcribe Audio"
    /// rather than "Post-Process", which depends on this classification.
    private static func testTranscriptionStageFailuresAreRecognized() {
        let transcriptionFailures = [
            "Error: Transcription timed out: ZFlow stopped waiting after 38s.",
            "Error: Submission failed: zenmux.ai rejected the recording as too short (HTTP 400): only 0.4s of audio.",
            "Error: Upload failed: connection reset",
            "Error: Invalid provider URL: Provider URL must include a host.",
            "Error: Audio preparation failed: unsupported format"
        ]
        for status in transcriptionFailures {
            TestSupport.expect(
                TranscriptionErrorPresentationCore.isTranscriptionStageFailure(status: status),
                "Should be attributed to the transcription step: \(status)"
            )
        }

        let notTranscriptionFailures = [
            "Post-processing succeeded",
            "Post-processing off, using raw transcript",
            "Post-processing failed, using raw transcript",
            "Error: Something else entirely",
            ""
        ]
        for status in notTranscriptionFailures {
            TestSupport.expect(
                !TranscriptionErrorPresentationCore.isTranscriptionStageFailure(status: status),
                "Should not be attributed to the transcription step: \(status)"
            )
        }
    }

    /// A timeout carries the provider and audio length; the generic wording
    /// would throw both away.
    private static func testSelfDescribingErrorsKeepTheirOwnMessage() {
        struct SelfDescribing: Error, ShortDisplayableError {
            var shortDisplayMessage: String { "zenmux.ai did not answer within 38s for 24s of audio" }
        }

        TestSupport.expectEqual(
            TranscriptionErrorPresentationCore.message(for: SelfDescribing(), isOnline: true),
            "zenmux.ai did not answer within 38s for 24s of audio"
        )

        // Losing the connection arrives as a URLError, classified below, so a
        // self-describing error keeps its own wording in both states rather
        // than being rewritten as a network problem it did not report.
        TestSupport.expectEqual(
            TranscriptionErrorPresentationCore.message(for: SelfDescribing(), isOnline: false),
            "zenmux.ai did not answer within 38s for 24s of audio"
        )

        // A genuine offline failure is still diagnosed as one.
        TestSupport.expectEqual(
            TranscriptionErrorPresentationCore.message(
                for: URLError(.notConnectedToInternet),
                isOnline: false
            ),
            "No internet — check connection"
        )
    }

    private static func testConnectionLostOffersRetryAndNetworkGuidance() {
        TestSupport.expectEqual(
            TranscriptionErrorPresentationCore.message(
                for: URLError(.networkConnectionLost),
                isOnline: true
            ),
            "Connection lost — retry or try another network"
        )
    }

    private static func testOfflineFailuresRemainClassifiedAsNoInternet() {
        let offlineCodes: [URLError.Code] = [
            .notConnectedToInternet,
            .cannotConnectToHost,
            .cannotFindHost,
            .dnsLookupFailed
        ]

        for code in offlineCodes {
            TestSupport.expectEqual(
                TranscriptionErrorPresentationCore.message(
                    for: URLError(code),
                    isOnline: true
                ),
                "No internet — check connection"
            )
        }
    }
}
