import Foundation
import ApplicationServices
import AppKit
import os.log

private let correctionLog = OSLog(
    subsystem: "com.zippy.zflow",
    category: "CorrectionWatcher"
)

/// Watches the field ZFlow just pasted into, and reports words the user
/// respelled by hand.
///
/// Everything stays on this Mac: the field's text is read through the same
/// Accessibility APIs the app already uses for context, compared in memory,
/// and discarded. Nothing is stored except the word pair the user corrected,
/// and nothing is transmitted.
/// Created and driven from the main thread, like the rest of the app's AppKit
/// state; the polling timer is scheduled on the main run loop.
final class CorrectionWatcher: @unchecked Sendable {
    /// Every Accessibility read happens here, never on the main thread.
    ///
    /// Reading another app's tree is not cheap — an Electron window can be
    /// hundreds of elements deep — and doing it on the main thread stalled the
    /// whole app, including the moment the user pressed the dictation key.
    private let work = DispatchQueue(label: "com.zippy.zflow.correctionwatcher", qos: .utility)
    /// How long after a paste the user is likely still fixing that text. Past
    /// this the field has moved on and a diff would be noise.
    private static let watchDuration: TimeInterval = 45
    /// Polling beat. The read is cheap, and a short beat is what lets the
    /// settle tracker tell typing apart from a pause.
    private static let pollInterval: TimeInterval = 0.4
    /// Reading an enormous document to diff a sentence is not worth it.
    private static let maximumFieldLength = 20_000
    /// How long the field must hold still before the diff runs.
    private static let settleDelay: TimeInterval = EditSettleTracker.defaultSettleDelay
    /// Attaching to the field is retried: the paste lands asynchronously, and
    /// how long the target app takes to update its Accessibility tree varies a
    /// lot between a native field, an Electron app, and a web view.
    private static let attachAttempts = 8
    private static let attachRetryInterval: TimeInterval = 0.35
    /// Bounds on the tree walk used when an app does not report focus.
    private static let maximumSearchDepth = 12
    private static let maximumSearchBreadth = 40

    private var timer: DispatchSourceTimer?
    private var element: AXUIElement?
    private var pastedText: String = ""
    private var settleTracker: EditSettleTracker?
    private var reportedKeys = Set<String>()

    /// Called on the main actor with each newly detected correction.
    var onCorrectionDetected: ((WordCorrection) -> Void)?

    /// Called when the text was edited but no rule recognised a correction.
    /// Gives the caller the chance to ask a model whether it was one after all.
    var onUnrecognisedEdit: ((_ pasted: String, _ edited: String) -> Void)?

    /// Begins watching the focused field for edits to `pastedText`.
    ///
    /// Silently does nothing without Accessibility permission, which is the
    /// same trust boundary the rest of the app already needs to paste at all.
    func beginWatching(pastedText: String) {
        stop()

        // Every bail-out below is logged with its reason and never with the
        // text itself, so a silent failure can be diagnosed from Console
        // without the transcript leaving the machine.
        let trimmed = pastedText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Too short to diff meaningfully; a single word gives no anchor.
        guard trimmed.split(separator: " ").count >= 2 else {
            logPersistent("not watching: pasted text is a single word")
            return
        }
        guard AXIsProcessTrusted() else {
            logPersistent("not watching: Accessibility permission not granted")
            return
        }

        work.async { [weak self] in
            self?.attemptAttach(pastedText: trimmed, attemptsLeft: Self.attachAttempts)
        }
    }

    /// Tries to find the field the paste landed in, retrying while the target
    /// app catches up. Only the last failure is reported, so one dictation
    /// leaves one line in the log rather than eight.
    private func attemptAttach(pastedText trimmed: String, attemptsLeft: Int) {
        let isLastAttempt = attemptsLeft <= 1

        func retryOrFail(_ reason: StaticString, _ args: CVarArg...) {
            guard isLastAttempt else {
                work.asyncAfter(deadline: .now() + Self.attachRetryInterval) { [weak self] in
                    self?.attemptAttach(pastedText: trimmed, attemptsLeft: attemptsLeft - 1)
                }
                return
            }
            switch args.count {
            case 0: os_log(.default, log: correctionLog, reason)
            case 1: os_log(.default, log: correctionLog, reason, args[0])
            default: os_log(.default, log: correctionLog, reason, args[0], args[1])
            }
        }

        guard let focused = focusedTextElement(containing: trimmed) else {
            if isLastAttempt {
                logAccessibilityShape()
            }
            retryOrFail(
                "not watching: could not find the pasted text in any Accessibility element after %ld attempts",
                Self.attachAttempts
            )
            return
        }
        guard let value = stringValue(of: focused) else {
            retryOrFail(
                "not watching: the matched element exposes no text after %ld attempts",
                Self.attachAttempts
            )
            return
        }
        guard value.count <= Self.maximumFieldLength else {
            os_log(
                .default,
                log: correctionLog,
                "not watching: field is %ld characters, over the %ld limit",
                value.count,
                Self.maximumFieldLength
            )
            return
        }
        // The paste has to actually be in the field, or there is nothing to
        // compare against.
        guard value.contains(trimmed) else {
            retryOrFail(
                "not watching: the pasted text is not in the focused field after %ld attempts — the app may render its own editor",
                Self.attachAttempts
            )
            return
        }

        attach(element: focused, pastedText: trimmed, value: value)
    }

    private func attach(element focused: AXUIElement, pastedText trimmed: String, value: String) {
        os_log(
            .default,
            log: correctionLog,
            "watching a field of %ld characters for edits to %ld pasted characters",
            value.count,
            trimmed.count
        )

        element = focused
        self.pastedText = trimmed
        settleTracker = EditSettleTracker(
            baseline: value,
            startedAt: Date(),
            settleDelay: Self.settleDelay,
            maximumWatch: Self.watchDuration
        )
        reportedKeys.removeAll()

        // A repeating background source rather than a main run-loop timer, so
        // polling never competes with the UI or with starting a recording.
        let timer = DispatchSource.makeTimerSource(queue: work)
        timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
    }

    /// Diagnostics. Reasons and sizes, never the text itself: reading the field
    /// is only acceptable because its contents stay on this Mac.
    ///
    /// Uses the default level, which the unified log keeps on disk. `.info` is
    /// memory-only, so a failure reported at that level is gone by the time
    /// anyone runs `log show`.
    private func logPersistent(_ message: StaticString, _ args: CVarArg...) {
        switch args.count {
        case 0: os_log(.default, log: correctionLog, message)
        case 1: os_log(.default, log: correctionLog, message, args[0])
        default: os_log(.default, log: correctionLog, message, args[0], args[1])
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        element = nil
        pastedText = ""
        settleTracker = nil
        reportedKeys.removeAll()
    }

    private func poll() {
        guard let element else {
            stop()
            return
        }
        guard let current = stringValue(of: element) else {
            logPersistent("stopped watching: the field is no longer readable (focus moved, or the app closed it)")
            stop()
            return
        }
        guard current.count <= Self.maximumFieldLength else {
            logPersistent("stopped watching: the field grew past the %ld character limit", Self.maximumFieldLength)
            stop()
            return
        }

        // Wait for the typing to stop. Comparing on every keystroke would diff
        // against half-finished words.
        guard var tracker = settleTracker else { return }
        let outcome = tracker.observe(current, at: Date())
        settleTracker = tracker

        let settledValue: String
        switch outcome {
        case .waiting:
            return
        case .settled(let value):
            logPersistent("edit settled after %.1fs of no typing; comparing", Self.settleDelay)
            settledValue = value
        case .expired(let pending):
            guard let pending else {
                logPersistent("stopped watching: the %.0fs window expired with no edit", Self.watchDuration)
                stop()
                return
            }
            logPersistent("the %.0fs window expired while still typing; comparing what is there", Self.watchDuration)
            settledValue = pending
        }

        defer {
            if case .expired = outcome { stop() }
        }

        // Compare only the region that came from the dictation. Diffing the
        // whole field would treat everything the user types next as an edit.
        guard let edited = Self.editedRegion(pasted: pastedText, in: settledValue) else {
            logPersistent("edit settled but the dictated region could not be located; ignoring it")
            return
        }

        let found = CorrectionDetector.corrections(from: pastedText, to: edited)
        if found.isEmpty {
            logPersistent(
                "edit settled (region %ld chars vs %ld pasted) but no correction was recognised",
                edited.count,
                pastedText.count
            )
            let handler = onUnrecognisedEdit
            let pasted = pastedText
            DispatchQueue.main.async { handler?(pasted, edited) }
        }

        // Later edits are compared against what has already been reported.
        if var tracker = settleTracker {
            tracker.acceptAsBaseline(settledValue)
            settleTracker = tracker
        }

        for correction in found {
            let key = correction.id
            guard !reportedKeys.contains(key) else { continue }
            reportedKeys.insert(key)
            os_log(
                .info,
                log: correctionLog,
                "Learned a correction from an in-place edit (lengths %ld -> %ld)",
                correction.original.count,
                correction.corrected.count
            )
            let handler = onCorrectionDetected
            DispatchQueue.main.async { handler?(correction) }
        }
    }

    /// The slice of `field` that corresponds to the pasted text after editing.
    ///
    /// Anchored on the unchanged words at each end of the paste, so text the
    /// user typed before or after it is excluded.
    static func editedRegion(pasted: String, in field: String) -> String? {
        if let range = field.range(of: pasted) {
            return String(field[range])
        }

        let pastedTokens = CorrectionDetector.tokenize(pasted)
        guard pastedTokens.count >= 3 else { return nil }

        // Anchor on the first and last words of the paste; they are the least
        // likely to be the ones corrected.
        guard let head = pastedTokens.first, let tail = pastedTokens.last else { return nil }
        guard let headRange = field.range(of: head, options: [.caseInsensitive]) else { return nil }
        guard let tailRange = field.range(
            of: tail,
            options: [.caseInsensitive, .backwards],
            range: headRange.upperBound..<field.endIndex
        ) else { return nil }

        let region = String(field[headRange.lowerBound..<tailRange.upperBound])
        // If the anchors drifted far apart the user has written something else
        // between them; that is not an edit of this dictation.
        guard region.count <= pasted.count * 2 else { return nil }
        return region
    }

    /// Structural diagnostics for a failed attach: which lookups answered, and
    /// the roles that were seen. Roles are generic UI vocabulary, never the
    /// user's text, and the application is not named.
    private func logAccessibilityShape() {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            logPersistent("diagnostics: no frontmost application")
            return
        }
        let appElement = AXUIElementCreateApplication(frontmost.processIdentifier)

        let hasFocused = copyElement(from: appElement, attribute: kAXFocusedUIElementAttribute) != nil
        let window = copyElement(from: appElement, attribute: kAXFocusedWindowAttribute)
        logPersistent(
            "diagnostics: focused element %ld, focused window %ld",
            hasFocused ? 1 : 0,
            window != nil ? 1 : 0
        )

        let root = window ?? appElement
        var textElements = 0
        var visited = 0
        countTextElements(in: root, depth: 0, textElements: &textElements, visited: &visited)
        logPersistent(
            "diagnostics: walked %ld elements, %ld of them expose text",
            visited,
            textElements
        )
    }

    private func countTextElements(
        in element: AXUIElement,
        depth: Int,
        textElements: inout Int,
        visited: inout Int
    ) {
        guard depth <= Self.maximumSearchDepth, visited < 400 else { return }
        visited += 1
        if rawStringValue(of: element) != nil { textElements += 1 }

        var childrenValue: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue)
        guard status == .success, let children = childrenValue as? [AXUIElement] else { return }
        for child in children.prefix(Self.maximumSearchBreadth) {
            countTextElements(in: child, depth: depth + 1, textElements: &textElements, visited: &visited)
        }
    }

    /// The text element the user is typing in.
    ///
    /// Asks the frontmost application rather than the system-wide element.
    /// The system-wide query returns nothing here — ZFlow has just shown its
    /// own overlay panel, so "the focused element" from its point of view is
    /// not the field it pasted into. Going through the frontmost app's element
    /// is what the rest of the app already does to read selected text.
    private func focusedTextElement(containing pastedText: String) -> AXUIElement? {
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            let appElement = AXUIElementCreateApplication(frontmost.processIdentifier)
            enableChromiumAccessibility(on: appElement)

            if let focused = copyElement(from: appElement, attribute: kAXFocusedUIElementAttribute),
               stringValue(of: focused) != nil {
                return focused
            }
            // Focus is not always reported. Look for the text itself instead:
            // whichever element holds the paste is the one to watch.
            if let window = copyElement(from: appElement, attribute: kAXFocusedWindowAttribute),
               let match = searchForElement(containing: pastedText, in: window, depth: 0) {
                return match
            }
        }

        // Fallback for apps that only answer the system-wide query.
        let systemElement = AXUIElementCreateSystemWide()
        if let focused = copyElement(from: systemElement, attribute: kAXFocusedUIElementAttribute),
           stringValue(of: focused) != nil {
            return focused
        }
        return nil
    }

    /// Chromium-based apps — Electron, and browsers — ship a minimal
    /// Accessibility tree and only build the full one once a client asks for
    /// it. Without this they report no focused element at all, which is exactly
    /// what the log showed. Setting the attribute is harmless elsewhere.
    private func enableChromiumAccessibility(on appElement: AXUIElement) {
        AXUIElementSetAttributeValue(
            appElement,
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue
        )
    }

    /// Depth-first search for the element whose text contains the paste.
    /// Bounded, because an editor's tree can be large and this runs on the
    /// main thread.
    private func searchForElement(
        containing text: String,
        in element: AXUIElement,
        depth: Int
    ) -> AXUIElement? {
        guard depth <= Self.maximumSearchDepth else { return nil }

        if let value = rawStringValue(of: element),
           value.count <= Self.maximumFieldLength,
           value.contains(text) {
            return element
        }

        var childrenValue: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &childrenValue
        )
        guard status == .success, let children = childrenValue as? [AXUIElement] else { return nil }

        for child in children.prefix(Self.maximumSearchBreadth) {
            if let match = searchForElement(containing: text, in: child, depth: depth + 1) {
                return match
            }
        }
        return nil
    }

    private func copyElement(from element: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard status == .success,
              let raw = value,
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(raw, to: AXUIElement.self)
    }

    /// The element's text. Some editors expose it on the focused element, some
    /// on a text area just inside it, so one level is searched before giving up.
    private func stringValue(of element: AXUIElement) -> String? {
        if let direct = rawStringValue(of: element) { return direct }

        var childrenValue: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &childrenValue
        )
        guard status == .success, let children = childrenValue as? [AXUIElement] else { return nil }
        for child in children.prefix(8) {
            if let text = rawStringValue(of: child) { return text }
        }
        return nil
    }

    private func rawStringValue(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        guard status == .success, let text = value as? String, !text.isEmpty else { return nil }
        return text
    }
}
