import Foundation

/// Remaining life of a transient toast, advanced by the view's display timer.
///
/// Kept as a value type with no timer of its own so the dismissal rule is
/// testable: a toast that carries a button must not expire while the pointer is
/// over it, or the action disappears as the user reaches for it.
public struct ToastCountdown: Equatable {
    public let duration: TimeInterval
    public private(set) var remaining: TimeInterval
    /// While true, `advance(by:)` consumes no time.
    public var isPaused: Bool

    public init(duration: TimeInterval, isPaused: Bool = false) {
        let safeDuration = duration > 0 ? duration : 1
        self.duration = safeDuration
        self.remaining = safeDuration
        self.isPaused = isPaused
    }

    public mutating func advance(by seconds: TimeInterval) {
        guard !isPaused, seconds > 0 else { return }
        remaining = max(0, remaining - seconds)
    }

    /// Full life left at 1, none at 0 — drives the depleting bar directly.
    public var fractionRemaining: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, remaining / duration))
    }

    public var isExpired: Bool {
        remaining <= 0
    }

    /// Restores full life. Used when the pointer leaves the toast, so the user
    /// gets the whole window again rather than whatever sliver was left when
    /// they arrived.
    public mutating func reset() {
        remaining = duration
    }
}
