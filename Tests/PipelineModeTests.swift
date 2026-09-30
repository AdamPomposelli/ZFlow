import Foundation

enum PipelineModeTests {
    static func run() {
        testPresetStageCombinations()
        testMatchingRoundTrips()
        testUncoveredCombinationsHaveNoPreset()
        testPresetsAreDistinctAndDescribed()
    }

    private static func testPresetStageCombinations() {
        // Fast runs nothing after the transcription call.
        TestSupport.expectEqual(PipelineMode.fast.postProcessingEnabled, false)
        TestSupport.expectEqual(PipelineMode.fast.contextInferenceEnabled, false)
        TestSupport.expectEqual(PipelineMode.fast.screenshotEnabled, false)

        // Normal runs everything except the screenshot.
        TestSupport.expectEqual(PipelineMode.normal.postProcessingEnabled, true)
        TestSupport.expectEqual(PipelineMode.normal.contextInferenceEnabled, true)
        TestSupport.expectEqual(PipelineMode.normal.screenshotEnabled, false)

        // Quality runs everything.
        TestSupport.expectEqual(PipelineMode.quality.postProcessingEnabled, true)
        TestSupport.expectEqual(PipelineMode.quality.contextInferenceEnabled, true)
        TestSupport.expectEqual(PipelineMode.quality.screenshotEnabled, true)
    }

    private static func testMatchingRoundTrips() {
        // Applying a preset's stages must resolve back to that same preset, or
        // the picker would show "Custom" right after the user chose a mode.
        for mode in PipelineMode.allCases {
            TestSupport.expectEqual(
                PipelineMode.matching(
                    postProcessingEnabled: mode.postProcessingEnabled,
                    contextInferenceEnabled: mode.contextInferenceEnabled,
                    screenshotEnabled: mode.screenshotEnabled
                ),
                mode
            )
        }
    }

    private static func testUncoveredCombinationsHaveNoPreset() {
        // Cleanup on, context off.
        TestSupport.expectEqual(
            PipelineMode.matching(
                postProcessingEnabled: true,
                contextInferenceEnabled: false,
                screenshotEnabled: false
            ),
            nil
        )
        // Cleanup off but context on.
        TestSupport.expectEqual(
            PipelineMode.matching(
                postProcessingEnabled: false,
                contextInferenceEnabled: true,
                screenshotEnabled: false
            ),
            nil
        )
        // A screenshot with no context request to attach it to.
        TestSupport.expectEqual(
            PipelineMode.matching(
                postProcessingEnabled: false,
                contextInferenceEnabled: false,
                screenshotEnabled: true
            ),
            nil
        )
    }

    private static func testPresetsAreDistinctAndDescribed() {
        let stageSets = PipelineMode.allCases.map { mode in
            [mode.postProcessingEnabled, mode.contextInferenceEnabled, mode.screenshotEnabled]
        }
        TestSupport.expectEqual(Set(stageSets.map(String.init(describing:))).count, stageSets.count)

        for mode in PipelineMode.allCases {
            TestSupport.expect(!mode.title.isEmpty, "\(mode.rawValue) should have a title")
            TestSupport.expect(!mode.summary.isEmpty, "\(mode.rawValue) should have a summary")
        }
    }
}
