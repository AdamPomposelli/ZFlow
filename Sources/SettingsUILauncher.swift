import AppKit
import Foundation
import os.log

private let launcherLog = OSLog(subsystem: "com.zippy.zflow", category: "SettingsUI")

/// Opens the Electron settings window instead of the built-in one.
///
/// The native settings stay in the binary as a fallback: if the front end is
/// missing — someone running a build that was not packaged with it — the app
/// must still be configurable rather than silently doing nothing.
enum SettingsUILauncher {
    static let bundleIdentifier = "com.zippy.zflow.ui"

    /// Where the front end can be, in the order it is looked for: bundled
    /// inside this app for a release, then the repository's build output so a
    /// developer running from source gets it too.
    static func locateUI() -> URL? {
        var candidates: [URL] = []

        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("ZFlow UI.app"))
        }

        // Running from build/ZFlow Dev.app inside a checkout: walk up to the
        // repository root and look beside it.
        let executable = Bundle.main.bundleURL
        let repositoryRoot = executable.deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(
            repositoryRoot
                .appendingPathComponent("electron")
                .appendingPathComponent("release")
                .appendingPathComponent("ZFlow UI.app")
        )

        candidates.append(URL(fileURLWithPath: "/Applications/ZFlow UI.app"))

        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Closes the settings window along with the app.
    ///
    /// The window is a separate process, so quitting ZFlow would otherwise
    /// leave it on screen with nothing behind it — connected to a bridge that
    /// no longer answers.
    static func closeIfRunning() {
        for instance in NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ) {
            if !instance.terminate() { instance.forceTerminate() }
        }
    }

    /// The scheme the front end registers so it can be asked to come forward.
    private static let revealURL = URL(string: "zflow://settings")!

    /// Brings the front end forward, launching it if it is not already running.
    /// Returns false when it could not be found or started, so the caller can
    /// fall back to the native window.
    @discardableResult
    static func open() -> Bool {
        if let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).first {
            // Asking it to raise itself, rather than raising it from here.
            // macOS refuses one app the right to bring another's window
            // forward — cooperative activation — so clicking the Dock icon
            // left the window exactly where it was, behind everything. A URL
            // is always delivered to the running instance, and an app may
            // always raise its own window.
            // After the current activation, not during it. Clicking the Dock
            // icon makes macOS activate *this* app as it delivers the reopen,
            // and that activation lands after ours if we ask immediately —
            // leaving the menu-bar app in front and the window still behind.
            // After AppKit has finished activating this app, not during it.
            // Clicking the Dock icon activates the menu-bar app as part of
            // delivering the reopen, and that activation lands on top of an
            // immediate request — leaving the window exactly where it was.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                if !NSWorkspace.shared.open(revealURL) {
                    // No registration yet — a first run, or a bundle macOS has
                    // not seen. Activation is weaker but better than nothing.
                    running.activate(options: [.activateAllWindows])
                }
            }
            return true
        }

        guard let url = locateUI() else {
            os_log(
                .default,
                log: launcherLog,
                "settings front end not found; falling back to the built-in window"
            )
            return false
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                os_log(
                    .error,
                    log: launcherLog,
                    "could not open the settings front end: %{public}@",
                    error.localizedDescription
                )
            }
        }
        return true
    }
}
