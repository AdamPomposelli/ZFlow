import AppKit
import Foundation

/// How the app starts and how it shows itself.
enum AppLifecycleTests {
    static func run() {
        theDockIconFollowsTheSettingsWindow()
        nothingModalRunsDuringLaunch()
    }

    private static func theDockIconFollowsTheSettingsWindow() {
        TestSupport.expectEqual(DockVisibility.policy(showInDock: true, settingsWindowOpen: true), .regular)
        TestSupport.expectEqual(DockVisibility.policy(showInDock: true, settingsWindowOpen: false), .accessory)
        TestSupport.expectEqual(DockVisibility.policy(showInDock: false, settingsWindowOpen: true), .accessory)
        TestSupport.expectEqual(DockVisibility.policy(showInDock: false, settingsWindowOpen: false), .accessory)
    }

    /// The regression behind a dead shortcut: a blocking alert run from
    /// inside `applicationDidFinishLaunching`. It held the launch, could hide
    /// behind other windows in a menu-bar app, and froze every default-mode
    /// timer while open — the permission watch among them.
    ///
    /// Read from the source, because the harm is in where the call sits, and
    /// no amount of running the alert's own code would show it.
    private static func nothingModalRunsDuringLaunch() {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AppDelegate.swift")
        guard let source = try? String(contentsOf: url, encoding: .utf8),
              let start = source.range(of: "func applicationDidFinishLaunching")
        else {
            TestSupport.expect(false, "could not find applicationDidFinishLaunching in AppDelegate.swift")
            return
        }

        // The body runs to the next member of the class.
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    func ")?.lowerBound
            ?? rest.range(of: "\n    @objc")?.lowerBound
            ?? rest.endIndex
        let body = String(rest[..<end])

        for forbidden in ["runModal", "showAccessibilityAlert", "showMicrophonePermissionAlert", "beginModalSession"] {
            TestSupport.expect(
                !body.contains(forbidden),
                "applicationDidFinishLaunching calls \(forbidden): a modal at launch blocks startup and stalls the permission watch"
            )
        }
    }
}
