import Foundation

enum PermissionsCoreTests {
    static func run() {
        everythingGrantedLeavesNothingOutstanding()
        screenRecordingIsOnlyAskedForWhenSomethingUsesIt()
        aPermissionGivenAnywayReadsAsGiven()
        whatIsMissingIsCounted()
        everyAccessIsDescribed()
    }

    private static func everythingGrantedLeavesNothingOutstanding() {
        let items = PermissionsCore.items(
            microphoneGranted: true,
            accessibilityGranted: true,
            screenRecordingGranted: true,
            screenRecordingNeeded: true
        )
        TestSupport.expectEqual(items.count, 3)
        TestSupport.expect(
            PermissionsCore.everythingNeededIsGranted(items),
            "nothing should be outstanding when all three are given"
        )
        TestSupport.expectEqual(PermissionsCore.outstandingCount(items), 0)
    }

    /// The screenshot context is off by default, and an app that demands
    /// Screen Recording for a feature nobody switched on is asking for
    /// something it does not use.
    private static func screenRecordingIsOnlyAskedForWhenSomethingUsesIt() {
        let quiet = PermissionsCore.items(
            microphoneGranted: true,
            accessibilityGranted: true,
            screenRecordingGranted: false,
            screenRecordingNeeded: false
        )
        TestSupport.expectEqual(quiet[2].state, .notNeeded)
        TestSupport.expect(
            PermissionsCore.everythingNeededIsGranted(quiet),
            "a permission nothing uses should not be reported as outstanding"
        )

        let wanted = PermissionsCore.items(
            microphoneGranted: true,
            accessibilityGranted: true,
            screenRecordingGranted: false,
            screenRecordingNeeded: true
        )
        TestSupport.expectEqual(wanted[2].state, .missing)
        TestSupport.expect(
            !PermissionsCore.everythingNeededIsGranted(wanted),
            "a permission a switched-on feature needs should be reported as outstanding"
        )
    }

    /// Given earlier, for a setting since switched off: still given, and the
    /// page says so rather than pretending it is absent.
    private static func aPermissionGivenAnywayReadsAsGiven() {
        let items = PermissionsCore.items(
            microphoneGranted: true,
            accessibilityGranted: true,
            screenRecordingGranted: true,
            screenRecordingNeeded: false
        )
        TestSupport.expectEqual(items[2].state, .granted)
    }

    private static func whatIsMissingIsCounted() {
        let items = PermissionsCore.items(
            microphoneGranted: false,
            accessibilityGranted: false,
            screenRecordingGranted: false,
            screenRecordingNeeded: true
        )
        TestSupport.expectEqual(PermissionsCore.outstandingCount(items), 3)
        TestSupport.expectEqual(items[0].state, .missing)
        TestSupport.expectEqual(items[1].state, .missing)
    }

    private static func everyAccessIsDescribed() {
        for access in PermissionsCore.Access.allCases {
            TestSupport.expect(!PermissionsCore.title(for: access).isEmpty, "\(access) has no title")
            TestSupport.expect(!PermissionsCore.purpose(for: access).isEmpty, "\(access) has no purpose")
        }
        // The identifiers travel over the bridge, so they are part of the
        // contract with the settings window.
        TestSupport.expectEqual(PermissionsCore.Access.screenRecording.rawValue, "screen_recording")
        TestSupport.expectEqual(PermissionsCore.State.notNeeded.rawValue, "not_needed")
    }
}
