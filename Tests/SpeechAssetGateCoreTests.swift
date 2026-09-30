import Foundation

enum SpeechAssetGateCoreTests {
    static func run() {
        aModelOnDiskIsUsedWhateverTheInventorySays()
        aReservationLostToAServiceRestartDoesNotBlockDictation()
        aMissingModelIsFetched()
        aLocaleThisMacCannotHaveIsNotFetched()
        onlyTheExactLocaleCounts()
    }

    /// The regression. After Apple's speech service restarts, the status for
    /// an installed, working model reads `.supported`.
    private static func aReservationLostToAServiceRestartDoesNotBlockDictation() {
        TestSupport.expectEqual(
            SpeechAssetGateCore.decision(
                locale: "fr_FR",
                installedLocales: ["en_US", "fr_FR"],
                inventory: .supported
            ),
            .transcribe
        )
    }

    private static func aModelOnDiskIsUsedWhateverTheInventorySays() {
        for inventory: SpeechAssetGateCore.Inventory in [.unsupported, .supported, .downloading, .installed] {
            TestSupport.expectEqual(
                SpeechAssetGateCore.decision(
                    locale: "fr_FR",
                    installedLocales: ["fr_FR"],
                    inventory: inventory
                ),
                .transcribe
            )
        }
    }

    private static func aMissingModelIsFetched() {
        TestSupport.expectEqual(
            SpeechAssetGateCore.decision(locale: "de_DE", installedLocales: ["fr_FR"], inventory: .supported),
            .download
        )
        // Already on its way: wait for it rather than give up.
        TestSupport.expectEqual(
            SpeechAssetGateCore.decision(locale: "de_DE", installedLocales: [], inventory: .downloading),
            .download
        )
    }

    private static func aLocaleThisMacCannotHaveIsNotFetched() {
        TestSupport.expectEqual(
            SpeechAssetGateCore.decision(locale: "xx_XX", installedLocales: ["fr_FR"], inventory: .unsupported),
            .unsupported
        )
    }

    /// Canadian French being installed says nothing about France's.
    private static func onlyTheExactLocaleCounts() {
        TestSupport.expectEqual(
            SpeechAssetGateCore.decision(locale: "fr_FR", installedLocales: ["fr_CA", "fr_BE"], inventory: .supported),
            .download
        )
    }
}
