import Foundation

/// Counts kept about your own dictation, so the app can show you how you use
/// it.
///
/// Aggregates only: how many words, how long you spoke, which app you were in,
/// and which days you dictated. No transcript, no window title, nothing about
/// what was said — and nothing leaves the machine, because there is nowhere for
/// it to go. The run history already holds the texts themselves; this exists
/// because that history is capped at twenty entries and cannot answer "how much
/// have I dictated".
public struct UsageStatistics: Codable, Equatable {
    public var totalWords: Int = 0
    public var totalDictations: Int = 0
    public var totalSpeakingSeconds: Double = 0
    /// Audio actually handed to an engine, split by where that engine ran.
    /// Only the on-device half can be called money not spent; the other half
    /// was paid for.
    public var localAudioSeconds: Double = 0
    public var cloudAudioSeconds: Double = 0
    /// Learned-word replacements that actually fired in a finished dictation.
    public var correctionsApplied: Int = 0
    /// Words dictated per app name.
    public var wordsByApp: [String: Int] = [:]
    /// Dictations per calendar day, keyed yyyy-MM-dd in the local calendar.
    public var dictationsByDay: [String: Int] = [:]
    public var firstRecorded: Date?

    public init() {}

    /// Speaking pace. Short bursts make this meaningless, so it is only
    /// reported once there is a minute of speech to divide by.
    public var wordsPerMinute: Int? {
        guard totalSpeakingSeconds >= 60 else { return nil }
        return Int((Double(totalWords) / (totalSpeakingSeconds / 60)).rounded())
    }
}

public enum UsageStatisticsCore {
    /// How many words a finished transcript contains.
    ///
    /// Whitespace-separated runs that hold at least one letter or digit, so
    /// stray punctuation between words is not counted as a word of its own.
    public static func wordCount(of text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .filter { token in token.contains { $0.isLetter || $0.isNumber } }
            .count
    }

    public static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    public static func dayKey(for date: Date) -> String {
        dayFormatter.string(from: date)
    }

    /// Audio from a recorded meeting, which is not a dictation: it adds no
    /// words you would otherwise have typed, and no speaking time of yours.
    /// Only the minutes an engine processed.
    public static func recordingMeetingAudio(
        _ stats: UsageStatistics,
        seconds: Double,
        onDevice: Bool
    ) -> UsageStatistics {
        guard seconds > 0 else { return stats }
        var next = stats
        if onDevice {
            next.localAudioSeconds += seconds
        } else {
            next.cloudAudioSeconds += seconds
        }
        return next
    }

    /// Folds one finished dictation into the counts.
    ///
    /// An empty transcript still counts as nothing rather than as a dictation:
    /// a run that heard nothing is not use.
    public static func recording(
        _ stats: UsageStatistics,
        transcript: String,
        speakingSeconds: Double,
        appName: String?,
        correctionsApplied: Int,
        onDevice: Bool,
        at date: Date
    ) -> UsageStatistics {
        let words = wordCount(of: transcript)
        guard words > 0 else { return stats }

        var next = stats
        next.totalWords += words
        next.totalDictations += 1
        // A clock that ran backwards, or a session left open for an hour, would
        // otherwise poison the pace figure for good.
        if speakingSeconds > 0, speakingSeconds < 3600 {
            next.totalSpeakingSeconds += speakingSeconds
            if onDevice {
                next.localAudioSeconds += speakingSeconds
            } else {
                next.cloudAudioSeconds += speakingSeconds
            }
        }
        next.correctionsApplied += max(0, correctionsApplied)
        if let appName, !appName.isEmpty {
            next.wordsByApp[appName, default: 0] += words
        }
        next.dictationsByDay[dayKey(for: date), default: 0] += 1
        if next.firstRecorded == nil { next.firstRecorded = date }
        return pruned(next)
    }

    /// Keeps the per-day map to roughly the window the heat map can show.
    static func pruned(_ stats: UsageStatistics, keepingDays: Int = 400) -> UsageStatistics {
        guard stats.dictationsByDay.count > keepingDays else { return stats }
        var next = stats
        let keep = Set(stats.dictationsByDay.keys.sorted().suffix(keepingDays))
        next.dictationsByDay = next.dictationsByDay.filter { keep.contains($0.key) }
        return next
    }

    /// Days dictated in an unbroken run ending today, or yesterday.
    ///
    /// Yesterday still counts: a streak that resets at midnight would read as
    /// broken every morning before the first dictation of the day.
    public static func currentStreak(
        days: [String: Int],
        today: Date,
        calendar: Calendar = .current
    ) -> Int {
        let active = Set(days.filter { $0.value > 0 }.keys)
        guard !active.isEmpty else { return 0 }

        var cursor = today
        if !active.contains(dayKey(for: cursor)) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor),
                  active.contains(dayKey(for: yesterday)) else { return 0 }
            cursor = yesterday
        }

        var streak = 0
        while active.contains(dayKey(for: cursor)) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }

    public static func longestStreak(
        days: [String: Int],
        calendar: Calendar = .current
    ) -> Int {
        let active = days.filter { $0.value > 0 }.keys.sorted()
        guard !active.isEmpty else { return 0 }

        var longest = 1
        var run = 1
        for index in 1..<max(active.count, 1) {
            guard let previous = dayFormatter.date(from: active[index - 1]),
                  let current = dayFormatter.date(from: active[index]),
                  let expected = calendar.date(byAdding: .day, value: 1, to: previous) else {
                run = 1
                continue
            }
            run = calendar.isDate(current, inSameDayAs: expected) ? run + 1 : 1
            longest = max(longest, run)
        }
        return longest
    }
}
