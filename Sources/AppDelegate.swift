import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var settingsWindow: NSWindow?

    /// Before the first frame, so an app set to stay out of the Dock does not
    /// flash an icon on the way up.
    func applicationWillFinishLaunching(_ notification: Notification) {
        DockVisibility.apply()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DockVisibility.followSettingsWindow(
            bundleIdentifier: SettingsUILauncher.bundleIdentifier
        )
        NetworkMonitor.shared.start()
        DockVisibility.apply()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowSettings),
            name: .showSettings,
            object: nil
        )

        // Settings, including permissions, live in the front end now, so
        // there is no wizard to gate startup on.
        appState.startHotkeyMonitoring()
        appState.startAccessibilityPolling()
        Task { @MainActor in
            UpdateManager.shared.startPeriodicChecks()
        }

        // Nothing modal at launch. This used to be a blocking alert run from
        // inside this very method: it held the whole launch until dismissed,
        // could sit unseen behind other windows in a menu-bar app, and froze
        // every default-mode timer while it was up — including the one meant
        // to notice the permission being granted. The settings window opens
        // on the permissions instead, and nothing waits on it.
        if !appState.allNeededPermissionsGranted {
            showSettingsWindow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The settings window is another process. Without this it survives the
        // app it belongs to, talking to a bridge that has gone.
        SettingsUILauncher.closeIfRunning()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showSettingsWindow()
        }
        return true
    }


    @objc private func handleShowSettings() {
        showSettingsWindow()
    }

    private func showSettingsWindow() {
        // The Electron front end is the settings surface now. The built-in
        // window below stays as a fallback for a build shipped without it.
        if SettingsUILauncher.open() { return }

        NSApp.setActivationPolicy(.regular)

        if let settingsWindow, settingsWindow.isVisible {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        if settingsWindow == nil {
            presentSettingsWindow()
        } else {
            settingsWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func presentSettingsWindow() {
        let settingsView = SettingsView()
            .environmentObject(appState)
        let hostingView = NSHostingView(rootView: settingsView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 540),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = AppName.displayName
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        settingsWindow = window

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            // Back to whatever the Dock preference says, not unconditionally
            // hidden: the window forced `.regular` to show itself.
            NSApp.setActivationPolicy(DockVisibility.restingPolicy)
            self?.settingsWindow = nil
        }
    }



}
