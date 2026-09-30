import Foundation

/// The system permissions ZFlow needs, and what to say about each one.
///
/// Pure: it is handed the answers and decides what the page shows. Asking the
/// system is the caller's job, so this can be tested without a Mac agreeing
/// to anything.
enum PermissionsCore {
    enum Access: String, CaseIterable {
        case microphone
        case accessibility
        case screenRecording = "screen_recording"
    }

    enum State: String {
        /// Given. Nothing to do.
        case granted
        /// Needed for something that is switched on, and not given.
        case missing
        /// Nothing currently switched on uses it, so it is not asked for.
        case notNeeded = "not_needed"
    }

    struct Item {
        let access: Access
        let title: String
        let purpose: String
        let state: State
    }

    static func title(for access: Access) -> String {
        switch access {
        case .microphone: return "Microphone"
        case .accessibility: return "Accessibility"
        case .screenRecording: return "Screen Recording"
        }
    }

    static func purpose(for access: Access) -> String {
        switch access {
        case .microphone:
            return "Hearing you. Without it there is nothing to transcribe."
        case .accessibility:
            return "Reading the text you selected and typing the result back into the app you are in."
        case .screenRecording:
            return "Taking the screenshot that gives the cleanup step its context, and recording the other side of a meeting."
        }
    }

    /// Screen Recording is the only conditional one: it is asked for when the
    /// screenshot context is switched on, and left alone otherwise. The other
    /// two are what dictation is made of.
    static func items(
        microphoneGranted: Bool,
        accessibilityGranted: Bool,
        screenRecordingGranted: Bool,
        screenRecordingNeeded: Bool
    ) -> [Item] {
        func state(granted: Bool, needed: Bool = true) -> State {
            if granted { return .granted }
            return needed ? .missing : .notNeeded
        }

        return [
            Item(
                access: .microphone,
                title: title(for: .microphone),
                purpose: purpose(for: .microphone),
                state: state(granted: microphoneGranted)
            ),
            Item(
                access: .accessibility,
                title: title(for: .accessibility),
                purpose: purpose(for: .accessibility),
                state: state(granted: accessibilityGranted)
            ),
            Item(
                access: .screenRecording,
                title: title(for: .screenRecording),
                purpose: purpose(for: .screenRecording),
                state: state(granted: screenRecordingGranted, needed: screenRecordingNeeded)
            ),
        ]
    }

    /// True when nothing is outstanding. A permission nobody needs does not
    /// count as outstanding.
    static func everythingNeededIsGranted(_ items: [Item]) -> Bool {
        !items.contains { $0.state == .missing }
    }

    /// How many are still to be given, for a one-line summary.
    static func outstandingCount(_ items: [Item]) -> Int {
        items.filter { $0.state == .missing }.count
    }
}
