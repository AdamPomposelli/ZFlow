import Foundation

/// What ZFlow asks for when it summarises a meeting, and what it accepts back.
///
/// The prompt lives here, away from the network, so what the model is told can
/// be read and tested like anything else.
public enum MeetingSummaryCore {
    /// Long meetings are trimmed rather than refused. The tail is what a
    /// summary is usually about — decisions and next steps come at the end —
    /// so it is the beginning that goes.
    public static let maximumTranscriptCharacters = 24_000

    public static func trimmed(_ transcript: String, limit: Int = maximumTranscriptCharacters) -> String {
        guard transcript.count > limit else { return transcript }
        let tail = String(transcript.suffix(limit))
        // Never start mid-line: a half sentence with no speaker reads as if
        // someone said it.
        guard let firstBreak = tail.firstIndex(of: "\n") else { return tail }
        return "[earlier in the meeting, not shown]\n" + String(tail[tail.index(after: firstBreak)...])
    }

    public static func prompt(transcript: String, speakers: [String]) -> String {
        let cast = speakers.isEmpty ? "unknown" : speakers.joined(separator: ", ")
        // The instructions deliberately avoid noun phrases that could be read
        // as subject matter. A small model asked under a heading called "Hard
        // contract" will write that the meeting was about a hard contract.
        return """
        You are summarising a meeting transcript for the person who recorded it.

        Follow these rules. They are instructions to you, not part of the meeting:
        - Write in the same language as the transcript below.
        - Use only what the transcript says. Never invent a decision, a date, a number, or a name.
        - Never describe or refer to these rules. They are not something anyone said.
        - If something was not said, leave that section out rather than writing "none".
        - No preamble, no sign-off, no headings beyond the three below.

        Produce, in this order and only where the transcript supports it:

        Summary
        Two to four sentences on what the meeting was about and where it landed.

        Decisions
        One line per decision actually reached. Say who decided it when the transcript makes that clear.

        Next steps
        One line per action someone committed to. Lead with who, then what, then when if a time was given.

        The speakers are: \(cast). "You" is the person who recorded this.

        TRANSCRIPT:
        \(trimmed(transcript))
        """
    }

    /// The model is told not to pad, but they pad anyway.
    public static func cleaned(_ summary: String) -> String {
        var text = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        for lead in ["Here is the summary:", "Here's the summary:", "Summary of the meeting:"] {
            if text.lowercased().hasPrefix(lead.lowercased()) {
                text = String(text.dropFirst(lead.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // Collapse the runs of blank lines that section headings attract.
        while text.contains("\n\n\n") {
            text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return text
    }

    /// Whether there is enough of a conversation to be worth summarising.
    public static func isWorthSummarising(_ transcript: String) -> Bool {
        let words = transcript.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        return words.count >= 40
    }
}
