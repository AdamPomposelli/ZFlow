import Foundation

enum TranscriptionEngineTests {
    static func run() {
        testStoredValuesNormalize()
        testEnginesAreDescribed()
        testRetryGoesWhereTheFirstAttemptWent()
    }

    private static func testStoredValuesNormalize() {
        // Cloud is the default so an upgrade never silently moves an existing
        // user onto a different engine.
        TestSupport.expectEqual(TranscriptionEngine.normalized(nil), .cloud)
        TestSupport.expectEqual(TranscriptionEngine.normalized(""), .cloud)
        TestSupport.expectEqual(TranscriptionEngine.normalized("nonsense"), .cloud)
        TestSupport.expectEqual(TranscriptionEngine.normalized(" Local "), .local)
        TestSupport.expectEqual(TranscriptionEngine.normalized("LOCAL"), .local)
        TestSupport.expectEqual(TranscriptionEngine.normalized("cloud"), .cloud)

        // Round trip through the stored raw value.
        for engine in TranscriptionEngine.allCases {
            TestSupport.expectEqual(TranscriptionEngine.normalized(engine.rawValue), engine)
        }
    }

    private static func testEnginesAreDescribed() {
        for engine in TranscriptionEngine.allCases {
            TestSupport.expect(!engine.displayName.isEmpty, "\(engine.rawValue) needs a name")
            TestSupport.expect(!engine.summary.isEmpty, "\(engine.rawValue) needs a summary")
        }
        // The local engine's trade-off must be stated, not buried.
        let local = TranscriptionEngine.local.summary.lowercased()
        TestSupport.expect(local.contains("macos 26"), "Local should state its OS requirement")
        TestSupport.expect(
            local.contains("less precise") || local.contains("less accurate"),
            "Local should state its accuracy trade-off"
        )
    }

    /// The regression: Retry uploaded on-device recordings to the provider.
    private static func testRetryGoesWhereTheFirstAttemptWent() {
        TestSupport.expectEqual(TranscriptionEngine.local.retryRoute(localSupported: true), .onDevice)
        TestSupport.expectEqual(TranscriptionEngine.cloud.retryRoute(localSupported: true), .provider)
        TestSupport.expectEqual(TranscriptionEngine.cloud.retryRoute(localSupported: false), .provider)
        // Never the provider for a recording meant to stay on this Mac, even
        // when this Mac cannot transcribe it.
        TestSupport.expectEqual(TranscriptionEngine.local.retryRoute(localSupported: false), .unavailable)
    }
}
