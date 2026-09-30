import Foundation

enum HotkeyRecoveryCoreTests {
    static func run() {
        grantingAccessibilityLaterBringsTheShortcutBack()
        nothingIsInstalledWithoutAccessibility()
        aWorkingTapIsLeftAlone()
        anUnwantedTapIsNotInstalled()
        allGrantedIsNotEnoughToStopWatching()
        watchingStopsOnceEverythingWorks()
    }

    /// The regression: launched without Accessibility, granted a few seconds
    /// later. The tap is missing and now allowed, so it goes back in.
    private static func grantingAccessibilityLaterBringsTheShortcutBack() {
        TestSupport.expect(
            HotkeyRecoveryCore.shouldInstallTap(
                monitoringWanted: true,
                tapInstalled: false,
                accessibilityTrusted: true
            ),
            "a missing tap should be installed once Accessibility is granted"
        )
    }

    private static func nothingIsInstalledWithoutAccessibility() {
        TestSupport.expect(
            !HotkeyRecoveryCore.shouldInstallTap(
                monitoringWanted: true,
                tapInstalled: false,
                accessibilityTrusted: false
            ),
            "retrying without Accessibility can only fail again"
        )
    }

    private static func aWorkingTapIsLeftAlone() {
        TestSupport.expect(
            !HotkeyRecoveryCore.shouldInstallTap(
                monitoringWanted: true,
                tapInstalled: true,
                accessibilityTrusted: true
            ),
            "a tap that is already listening should not be torn down and rebuilt"
        )
    }

    /// While a shortcut is being recorded, or the microphone prompt is up,
    /// monitoring is paused on purpose.
    private static func anUnwantedTapIsNotInstalled() {
        TestSupport.expect(
            !HotkeyRecoveryCore.shouldInstallTap(
                monitoringWanted: false,
                tapInstalled: false,
                accessibilityTrusted: true
            ),
            "a deliberately paused shortcut should stay paused"
        )
    }

    /// The other half of the regression: every permission green, shortcut
    /// dead, and the watch that could have noticed had already stopped.
    private static func allGrantedIsNotEnoughToStopWatching() {
        TestSupport.expect(
            !HotkeyRecoveryCore.canStopWatching(
                allNeededPermissionsGranted: true,
                monitoringWanted: true,
                tapInstalled: false
            ),
            "the watch must continue while the shortcut is not listening"
        )
        TestSupport.expect(
            !HotkeyRecoveryCore.canStopWatching(
                allNeededPermissionsGranted: false,
                monitoringWanted: true,
                tapInstalled: true
            ),
            "the watch must continue while a permission is missing"
        )
    }

    private static func watchingStopsOnceEverythingWorks() {
        TestSupport.expect(
            HotkeyRecoveryCore.canStopWatching(
                allNeededPermissionsGranted: true,
                monitoringWanted: true,
                tapInstalled: true
            ),
            "nothing left to recover"
        )
        TestSupport.expect(
            HotkeyRecoveryCore.canStopWatching(
                allNeededPermissionsGranted: true,
                monitoringWanted: false,
                tapInstalled: false
            ),
            "a paused shortcut is not a broken one"
        )
    }
}
