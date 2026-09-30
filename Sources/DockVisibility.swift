import AppKit

/// Whether ZFlow keeps an icon in the Dock.
///
/// The icon stands for the settings window, not for the app: ZFlow lives in
/// the menu bar, and a Dock tile that opens nothing is a tile that does
/// nothing. So it appears when the window does, goes when the window goes,
/// and only for someone who asked for it at all.
enum DockVisibility {
    static let storageKey = "show_app_in_dock"

    /// Defaults to true: that is what the app did before this was a choice.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: storageKey) as? Bool ?? true
    }

    private(set) static var settingsWindowIsOpen = false
    private static var watcher: DispatchSourceTimer?

    @MainActor
    static func settingsWindowChanged(open: Bool) {
        guard open != settingsWindowIsOpen else { return }
        settingsWindowIsOpen = open
        apply()
    }

    static var restingPolicy: NSApplication.ActivationPolicy {
        policy(showInDock: isEnabled, settingsWindowOpen: settingsWindowIsOpen)
    }

    /// The icon is there only while it would open something, and only for
    /// someone who asked for it.
    static func policy(showInDock: Bool, settingsWindowOpen: Bool) -> NSApplication.ActivationPolicy {
        showInDock && settingsWindowOpen ? .regular : .accessory
    }

    @MainActor
    static func apply() {
        NSApp.setActivationPolicy(restingPolicy)
    }

    private nonisolated static func isRunning(_ bundleIdentifier: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    /// Follows the settings window by following its process.
    ///
    /// The window and its process live and die together — closing the window
    /// ends it — so "is it running" is the same question as "is the window
    /// there".
    ///
    /// Asked on a timer rather than observed. `NSWorkspace` posts no launch or
    /// termination notification for the settings window, because an accessory
    /// app is not one of the applications it reports on, so an observer here
    /// never fires. Being told over the bridge instead took three messages
    /// that could each go missing — open, close, and the crash that says
    /// nothing — and the close one did: the request died with the process
    /// sending it. Asking costs a table lookup, and cannot be missed.
    ///
    /// A dispatch source rather than a `Timer`: a scheduled `Timer` never
    /// fired once here, the run loop of a menu-bar app not being in the
    /// mode it waits for.
    @MainActor
    static func followSettingsWindow(bundleIdentifier: String) {
        watcher?.cancel()

        settingsWindowIsOpen = isRunning(bundleIdentifier)
        apply()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1.5, repeating: 1.5, leeway: .milliseconds(500))
        timer.setEventHandler {
            MainActor.assumeIsolated {
                settingsWindowChanged(open: isRunning(bundleIdentifier))
            }
        }
        timer.resume()
        watcher = timer
    }
}
