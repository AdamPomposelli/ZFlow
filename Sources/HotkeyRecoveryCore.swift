import Foundation

/// When the global shortcut has to be installed again, and when it is safe to
/// stop watching for that.
///
/// Pure, so the rules are tested without a keyboard or a permission prompt.
///
/// The shortcut is an event tap, and macOS refuses one to an app without
/// Accessibility. On a first launch — or after any rebuild that resets the
/// grant — the tap therefore fails at startup, before anyone has had a chance
/// to grant anything. Granting it afterwards changed nothing: the tap was
/// never tried again, the permission page said every access was granted, and
/// pressing the shortcut did nothing at all until the app was relaunched.
enum HotkeyRecoveryCore {
    /// Install the tap now: it is wanted, it is not there, and macOS would
    /// now allow it.
    static func shouldInstallTap(
        monitoringWanted: Bool,
        tapInstalled: Bool,
        accessibilityTrusted: Bool
    ) -> Bool {
        monitoringWanted && !tapInstalled && accessibilityTrusted
    }

    /// The watch can end only once nothing is left to recover: every needed
    /// permission is granted *and* the shortcut is actually listening.
    /// "All granted" alone is what let a dead shortcut go unnoticed.
    static func canStopWatching(
        allNeededPermissionsGranted: Bool,
        monitoringWanted: Bool,
        tapInstalled: Bool
    ) -> Bool {
        allNeededPermissionsGranted && (!monitoringWanted || tapInstalled)
    }
}
