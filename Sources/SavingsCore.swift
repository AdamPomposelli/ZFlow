import Foundation

/// What using ZFlow did not cost, and what it did not take.
///
/// Both numbers are easy to inflate and worthless once inflated, so they are
/// built from things that were actually counted and from rates that are
/// written down here rather than chosen to look good:
///
/// - Only audio transcribed **on this Mac** counts as money not spent. Audio
///   sent to a provider was paid for, and comparing one provider's bill to
///   another's is not a saving.
/// - Time is the difference between saying something and typing it, at a
///   stated typing speed. Not "time saved" in any grander sense.
public enum SavingsCore {
    /// OpenAI's published rate for speech to text, per minute of audio.
    /// Whisper and the gpt-4o transcribe models have both been $0.006/min.
    public static let referenceTranscriptionCostPerMinute = 0.006

    /// A competent touch-typist. Deliberately not a slow one: a flattering
    /// assumption here would make the whole figure meaningless.
    public static let typingWordsPerMinute = 40.0

    /// What the audio handled on this Mac would have cost at that rate.
    public static func moneyNotSpent(localSeconds: Double) -> Double {
        guard localSeconds > 0 else { return 0 }
        return (localSeconds / 60) * referenceTranscriptionCostPerMinute
    }

    /// Minutes between saying it and typing it.
    ///
    /// Negative results are reported as zero rather than as a loss: dictating
    /// one word slowly is not evidence that dictation is slower, it is too
    /// little to say anything at all.
    public static func minutesNotSpentTyping(words: Int, speakingSeconds: Double) -> Double {
        guard words > 0 else { return 0 }
        let typing = Double(words) / typingWordsPerMinute
        let speaking = speakingSeconds / 60
        return max(0, typing - speaking)
    }

    /// How long a figure has to be before it is worth showing.
    ///
    /// Under a minute saved and under a cent, these read as noise and invite
    /// the reader to distrust the rest of the page.
    public static func isWorthShowing(minutesSaved: Double, moneySaved: Double) -> Bool {
        minutesSaved >= 1 || moneySaved >= 0.01
    }

    /// "2 min", "1 h 20", "3 days" — the largest honest unit.
    public static func readableDuration(minutes: Double) -> String {
        guard minutes >= 1 else { return "under a minute" }
        if minutes < 60 { return "\(Int(minutes.rounded())) min" }
        let hours = minutes / 60
        if hours < 24 {
            // Rounded, not truncated: 80 minutes is "1 h 20", and floating
            // point makes it 19 if you simply cut.
            let totalMinutes = Int(minutes.rounded())
            let whole = totalMinutes / 60
            let rest = totalMinutes % 60
            return rest == 0 ? "\(whole) h" : "\(whole) h \(rest)"
        }
        let days = hours / 24
        return days < 2 ? "1 day" : String(format: "%.1f days", days)
    }

    public static func readableMoney(_ dollars: Double) -> String {
        if dollars < 0.01 { return "$0.00" }
        if dollars < 10 { return String(format: "$%.2f", dollars) }
        return String(format: "$%.0f", dollars)
    }
}
