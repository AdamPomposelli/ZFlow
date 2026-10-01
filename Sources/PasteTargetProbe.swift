import AppKit
import ApplicationServices

/// Reads what had the focus when ZFlow pasted, for `PasteTargetCore` to judge.
///
/// Off the main thread, with a short timeout on every call: a slow or busy
/// app must never freeze ZFlow. Only roles and capabilities are read — never
/// the field's contents.
enum PasteTargetProbe {
    private static let queue = DispatchQueue(label: "com.zippy.zflow.paste-target", qos: .userInitiated)
    private static let messagingTimeout: Float = 0.3

    /// Judges the current focus and answers on the main queue.
    static func check(completion: @escaping @MainActor (PasteTargetCore.Verdict) -> Void) {
        queue.async {
            let verdict = classify()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(verdict) }
            }
        }
    }

    private enum Read {
        case focused(AXUIElement)
        /// The app answered, and nothing in it has the focus.
        case nothingFocused
        /// No answer worth acting on: no permission, a timeout, an app that
        /// does not implement it.
        case unavailable
    }

    private static func classify() -> PasteTargetCore.Verdict {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else {
            return .unknown
        }
        let pid = app.processIdentifier

        var read = focusedElement(of: pid)
        if case .nothingFocused = read {
            // A Chromium app asked for its full tree a moment ago may not have
            // built it yet; one short second look before concluding.
            Thread.sleep(forTimeInterval: 0.2)
            read = focusedElement(of: pid)
        }
        if case .nothingFocused = read, let element = systemWideFocus(belongingTo: pid) {
            read = .focused(element)
        }

        switch read {
        case .unavailable:
            return .unknown
        case .nothingFocused:
            return PasteTargetCore.verdict(for: nil)
        case .focused(let element):
            return PasteTargetCore.verdict(for: focus(of: element))
        }
    }

    private static func focusedElement(of pid: pid_t) -> Read {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
        // Chromium-based apps — Electron, browsers — only expose their full
        // tree once a client asks; the correction watcher does the same.
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &value
        )
        switch status {
        case .success:
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return .unavailable }
            return .focused(value as! AXUIElement)
        case .noValue:
            return .nothingFocused
        default:
            return .unavailable
        }
    }

    /// Some apps only answer the system-wide query. Its answer counts only if
    /// it belongs to the app in front — never to ZFlow's own overlay.
    private static func systemWideFocus(belongingTo pid: pid_t) -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        var owner: pid_t = 0
        guard AXUIElementGetPid(element, &owner) == .success, owner == pid else { return nil }
        return element
    }

    private static func focus(of element: AXUIElement) -> PasteTargetCore.Focus {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)

        func string(_ attribute: String) -> String? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
                return nil
            }
            return value as? String
        }

        var settable = DarwinBoolean(false)
        let valueSettable = AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &settable
        ) == .success && settable.boolValue

        var caret: CFTypeRef?
        let hasInsertionPoint = AXUIElementCopyAttributeValue(
            element,
            kAXInsertionPointLineNumberAttribute as CFString,
            &caret
        ) == .success

        return PasteTargetCore.Focus(
            role: string(kAXRoleAttribute),
            subrole: string(kAXSubroleAttribute),
            valueSettable: valueSettable,
            hasInsertionPoint: hasInsertionPoint
        )
    }
}
