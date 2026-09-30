import AppKit
import SwiftUI

@main
struct ZFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("show_menu_bar_icon") private var showMenuBarIcon = true

    var body: some Scene {
        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarView()
                .environmentObject(appDelegate.appState)
        } label: {
            MenuBarLabel()
                .environmentObject(appDelegate.appState)
        }
    }
}

@MainActor
struct MenuBarLabel: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var notificationManager = VocabularyNotificationManager.shared

    private var iconName: String {
        if appState.isRecording { return "record.circle" }
        if appState.isTranscribing { return "ellipsis.circle" }
        return "waveform"
    }

    var body: some View {
        HStack(spacing: 4) {
            if notificationManager.showCheckmark {
                Image(systemName: "checkmark")
            }
            if appState.isRecording || appState.isTranscribing {
                // Recording and transcribing keep their own symbols: what the
                // app is doing right now matters more than what it is called.
                Image(systemName: iconName)
            } else {
                Image(nsImage: ZFlowMenuBarIcon.templateImage)
                    .renderingMode(.template)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: notificationManager.showCheckmark)
    }
}

/// The ZFlow mark, drawn for the menu bar.
///
/// The same geometry as `Brand/logo/zflow-mark.svg` on its 32-unit grid, as a
/// template image so macOS tints it for light and dark menu bars. Drawn rather
/// than loaded: a menu bar icon has to be crisp at one size, and a scaled
/// bitmap of a 2.5-unit stroke is not.
enum ZFlowMenuBarIcon {
    static let templateImage: NSImage = {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let unit = side / 32
            func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
                // Flipped: the mark is specified top-down, AppKit draws bottom-up.
                NSPoint(x: x * unit, y: side - y * unit)
            }

            let stroke = NSBezierPath()
            stroke.move(to: point(12, 8))
            stroke.line(to: point(26, 8))
            stroke.curve(to: point(6, 24), controlPoint1: point(22, 14), controlPoint2: point(10, 18))
            stroke.line(to: point(20, 24))
            stroke.lineWidth = 2.5 * unit
            stroke.lineCapStyle = .round
            stroke.lineJoinStyle = .round
            NSColor.black.setStroke()
            stroke.stroke()

            NSColor.black.setFill()
            for corner in [(CGFloat(4), CGFloat(4)), (CGFloat(20), CGFloat(20))] {
                let origin = point(corner.0, corner.1 + 8)
                NSBezierPath(
                    roundedRect: NSRect(x: origin.x, y: origin.y, width: 8 * unit, height: 8 * unit),
                    xRadius: 2 * unit,
                    yRadius: 2 * unit
                ).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }()
}
