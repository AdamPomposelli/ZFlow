import Foundation

enum AppContextServiceTests {
    static func run() {
        testQwenRawOutputIsSummarized()
        testQwenReasoningOutputIsStripped()
        testNonStrippingModelPreservesExistingBehavior()
        testDeprecatedGroqModelsAreNotPredefined()
        testQwenCleanupDisablesReasoning()
        testMetadataOnlyActivityStatesWhatIsKnown()
    }

    /// With context inference off, no provider is asked what the user is doing,
    /// so the summary handed to the cleanup prompt must be built from the window
    /// metadata alone and must not read as a failed inference.
    private static func testMetadataOnlyActivityStatesWhatIsKnown() {
        TestSupport.expectEqual(
            AppContextService.metadataOnlyActivity(appName: "Notes", windowTitle: "Sprint plan"),
            "The user is dictating in Notes, in a window titled \"Sprint plan\"."
        )

        // Many apps report the app name as the window title; repeating it adds
        // nothing to the prompt.
        TestSupport.expectEqual(
            AppContextService.metadataOnlyActivity(appName: "Notes", windowTitle: "Notes"),
            "The user is dictating in Notes."
        )

        TestSupport.expectEqual(
            AppContextService.metadataOnlyActivity(appName: "Notes", windowTitle: nil),
            "The user is dictating in Notes."
        )

        TestSupport.expectEqual(
            AppContextService.metadataOnlyActivity(appName: nil, windowTitle: nil),
            "The user is dictating in an unknown application."
        )

        // The wording must not claim an inference was attempted and failed.
        TestSupport.expect(
            !AppContextService.metadataOnlyActivity(appName: "Notes", windowTitle: nil)
                .lowercased()
                .contains("could not"),
            "The disabled-inference summary should not read as a failure"
        )
    }

    private static func testQwenRawOutputIsSummarized() {
        let output = """
        The user is replying to an email about the product launch. They likely intend to confirm the next steps. This third sentence should be dropped.
        """

        let summary = AppContextService.activitySummary(from: output, model: "qwen/qwen3.6-27b")

        TestSupport.expectEqual(
            summary,
            "The user is replying to an email about the product launch. They likely intend to confirm the next steps."
        )
    }

    private static func testQwenReasoningOutputIsStripped() {
        let output = """
        <think>
        Hidden chain of thought should never appear in context.
        It contains misleading details.
        </think>
        The user is editing a project note in ZFlow. They likely intend to tighten the release wording.
        """

        let summary = AppContextService.activitySummary(from: output, model: "qwen/qwen3.6-27b")

        TestSupport.expectEqual(
            summary,
            "The user is editing a project note in ZFlow. They likely intend to tighten the release wording."
        )
        TestSupport.expect(summary?.contains("Hidden chain of thought") == false, "Qwen reasoning leaked into summary")
    }

    private static func testNonStrippingModelPreservesExistingBehavior() {
        let output = "<think>Visible for non-stripping models.</think> The user is writing a status update."

        let summary = AppContextService.activitySummary(
            from: output,
            model: "meta-llama/llama-4-scout-17b-16e-instruct"
        )

        TestSupport.expectEqual(summary, output)
    }

    private static func testDeprecatedGroqModelsAreNotPredefined() {
        let deprecatedModels = [
            "qwen/qwen3-32b",
            "meta-llama/llama-4-scout-17b-16e-instruct",
            "llama-3.1-8b-instant",
            "llama-3.3-70b-versatile"
        ]

        for model in deprecatedModels {
            TestSupport.expect(!ModelConfiguration.llmModels.contains(model), "Deprecated model remains in picker: \(model)")
        }
        TestSupport.expect(ModelConfiguration.llmModels.contains("qwen/qwen3.6-27b"), "New fallback is missing from picker")
    }

    private static func testQwenCleanupDisablesReasoning() {
        let config = ModelConfiguration.config(for: "qwen/qwen3.6-27b")

        TestSupport.expect(config.reasoningEffort == "none", "Qwen cleanup should disable reasoning")
        TestSupport.expect(config.includeReasoning == false, "Qwen cleanup should exclude reasoning output")
    }
}
