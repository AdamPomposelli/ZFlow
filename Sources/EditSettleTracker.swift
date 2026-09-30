import Foundation

/// Decides when the user has stopped editing, so the comparison runs once
/// against finished text.
///
/// Diffing on every change compares against half-typed words: while the user is
/// turning "Hoaven" into "Hoop Haven" the field passes through "Hoop", "Hoop H",
/// "Hoop Hav". Each of those is a different, wrong correction, and the first one
/// to look plausible would be the one learned. Waiting for the field to hold
/// still means the diff sees what the user meant to write.
public struct EditSettleTracker {
    /// How long the field must stay unchanged before it counts as finished.
    /// Long enough to cover thinking mid-sentence, short enough that the toast
    /// still feels like a response to what was just done.
    public static let defaultSettleDelay: TimeInterval = 2.0
    /// A hard stop, so someone who keeps typing for a minute does not hold the
    /// watcher open forever.
    public static let defaultMaximumWatch: TimeInterval = 45

    public let settleDelay: TimeInterval
    public let maximumWatch: TimeInterval
    public let startedAt: Date

    private var baseline: String
    private var latest: String
    private var lastChangeAt: Date?
    private var hasSettled = false

    public init(
        baseline: String,
        startedAt: Date,
        settleDelay: TimeInterval = EditSettleTracker.defaultSettleDelay,
        maximumWatch: TimeInterval = EditSettleTracker.defaultMaximumWatch
    ) {
        self.baseline = baseline
        self.latest = baseline
        self.startedAt = startedAt
        self.settleDelay = settleDelay
        self.maximumWatch = maximumWatch
    }

    public enum Outcome: Equatable {
        /// Nothing has changed, or the user is still typing.
        case waiting
        /// The field changed and has now held still: compare against this.
        case settled(String)
        /// The window is over. Carries the final text when there was an edit
        /// that never settled, so a long burst of typing is still examined.
        case expired(String?)
    }

    /// Feeds the tracker the field's current contents.
    public mutating func observe(_ value: String, at now: Date) -> Outcome {
        if value != latest {
            latest = value
            lastChangeAt = now
            hasSettled = false
        }

        if now.timeIntervalSince(startedAt) >= maximumWatch {
            // Report an unsettled edit rather than discarding it: better to
            // compare late than to drop what the user did.
            let pending = (!hasSettled && latest != baseline) ? latest : nil
            return .expired(pending)
        }

        guard !hasSettled else { return .waiting }
        guard latest != baseline else { return .waiting }
        guard let lastChangeAt else { return .waiting }
        guard now.timeIntervalSince(lastChangeAt) >= settleDelay else { return .waiting }

        hasSettled = true
        return .settled(latest)
    }

    /// Accepts the settled text as the new baseline, so a second round of
    /// edits is compared against what the user has already been told about
    /// rather than against the original paste.
    public mutating func acceptAsBaseline(_ value: String) {
        baseline = value
        latest = value
        lastChangeAt = nil
        hasSettled = false
    }
}
