import Foundation

/// A stretch of speech, with who said it and when.
public struct TranscriptSegment: Equatable {
    public var speaker: String
    public var text: String
    public var start: Double
    public var end: Double

    public init(speaker: String, text: String, start: Double, end: Double) {
        self.speaker = speaker
        self.text = text
        self.start = start
        self.end = end
    }
}

/// Who was talking, when — as diarization reports it, before any words are
/// attached.
public struct SpeakerTurn: Equatable {
    public var speaker: Int
    public var start: Double
    public var end: Double

    public init(speaker: Int, start: Double, end: Double) {
        self.speaker = speaker
        self.start = start
        self.end = end
    }
}

/// Turning several separately-transcribed tracks into one readable
/// conversation.
///
/// A meeting is recorded as two tracks — your microphone, and everything the
/// machine played — because that split is free and perfectly reliable: nothing
/// can mistake you for the other side. Diarization then only has to tell the
/// remote voices apart from each other, which is the part that is actually
/// hard. These functions do the joining, and they are the piece most likely to
/// be subtly wrong, so they live here where they can be tested without audio.
public enum TimedTranscriptCore {
    /// Interleaves tracks by time, and joins neighbouring segments from the
    /// same speaker so a transcript does not read as one line per breath.
    public static func merge(
        _ tracks: [[TranscriptSegment]],
        joiningGapUnder gap: Double = 1.5
    ) -> [TranscriptSegment] {
        let all: [TranscriptSegment] = tracks.flatMap { $0 }
        let spoken: [TranscriptSegment] = all.filter { segment in
            !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let ordered: [TranscriptSegment] = spoken.sorted { lhs, rhs in
            if lhs.start == rhs.start { return lhs.speaker < rhs.speaker }
            return lhs.start < rhs.start
        }

        var merged: [TranscriptSegment] = []
        for segment in ordered {
            guard var last = merged.last,
                  last.speaker == segment.speaker,
                  segment.start - last.end <= gap else {
                merged.append(segment)
                continue
            }
            let addition = segment.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            last.text += " " + addition
            last.end = max(last.end, segment.end)
            merged[merged.count - 1] = last
        }
        return merged
    }

    /// Gives each segment the speaker whose turn it overlaps most.
    ///
    /// Most, not first: a sentence that begins while someone else is finishing
    /// belongs to whoever said the bulk of it. A segment overlapping nothing
    /// keeps the label it already had, because a wrong name is worse than a
    /// general one.
    public static func labelling(
        _ segments: [TranscriptSegment],
        with turns: [SpeakerTurn],
        naming: (Int) -> String
    ) -> [TranscriptSegment] {
        guard !turns.isEmpty else { return segments }
        return segments.map { segment in
            var best: (speaker: Int, overlap: Double)?
            for turn in turns {
                let overlap = min(segment.end, turn.end) - max(segment.start, turn.start)
                guard overlap > 0 else { continue }
                if best == nil || overlap > best!.overlap {
                    best = (turn.speaker, overlap)
                }
            }
            guard let best else { return segment }
            var labelled = segment
            labelled.speaker = naming(best.speaker)
            return labelled
        }
    }

    /// Renumbers speakers so the first person heard is speaker 0.
    ///
    /// Clustering hands back arbitrary cluster ids — the person who spoke
    /// first can easily come back as speaker 3 — and "Speaker 4" opening a
    /// meeting with no Speaker 1 anywhere reads as a bug.
    public static func renumberingByFirstAppearance(_ turns: [SpeakerTurn]) -> [SpeakerTurn] {
        var mapping: [Int: Int] = [:]
        var next = 0
        for turn in turns.sorted(by: { $0.start < $1.start }) where mapping[turn.speaker] == nil {
            mapping[turn.speaker] = next
            next += 1
        }
        return turns.map { turn in
            SpeakerTurn(speaker: mapping[turn.speaker] ?? turn.speaker, start: turn.start, end: turn.end)
        }
    }

    /// Words shared between two lines, as a fraction of the *longer* one.
    ///
    /// Measured against the longer side on purpose. A line that merely
    /// contains another — your sentence plus the tail of theirs bleeding
    /// through — must not read as the same line, because dropping it would
    /// lose words you actually said. Only near-duplicates score high.
    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        func tokens(_ text: String) -> [String] {
            text.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter { $0.count > 2 }
        }
        let left = tokens(lhs)
        let right = Set(tokens(rhs))
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let shared = left.filter { right.contains($0) }.count
        return Double(shared) / Double(max(left.count, right.count))
    }

    /// Drops the lines your microphone only picked up because the speakers
    /// were playing them.
    ///
    /// Anyone on speakerphone records the far side twice: once cleanly on the
    /// system track, and once as bleed through their own microphone. Left in,
    /// every remote sentence appears a second time attributed to you, which is
    /// worse than useless — it says you said it.
    ///
    /// Only the microphone copy goes: the system track is the better recording
    /// of a remote voice, and it is the one that carries the speaker names.
    public static func removingEcho(
        from own: [TranscriptSegment],
        heardAlsoIn others: [TranscriptSegment],
        similarityAtLeast: Double = 0.55
    ) -> [TranscriptSegment] {
        guard !others.isEmpty else { return own }
        return own.filter { mine in
            let echoed = others.contains { theirs in
                // Only where the two overlap in time. The same words said
                // again a minute later are a person repeating themselves.
                let overlap = min(mine.end, theirs.end) - max(mine.start, theirs.start)
                guard overlap > 0.4 else { return false }
                return similarity(mine.text, theirs.text) >= similarityAtLeast
            }
            return !echoed
        }
    }

    public static func timestamp(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let minutes = total / 60
        let rest = total % 60
        return String(format: "%d:%02d", minutes, rest)
    }

    /// The transcript as a person reads it.
    public static func render(_ segments: [TranscriptSegment], withTimes: Bool = true) -> String {
        segments
            .map { segment in
                let head = withTimes
                    ? "[\(timestamp(segment.start))] \(segment.speaker):"
                    : "\(segment.speaker):"
                let body = segment.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                return "\(head) \(body)"
            }
            .joined(separator: "\n")
    }

    /// Distinct speakers in the order they first spoke.
    public static func speakers(in segments: [TranscriptSegment]) -> [String] {
        var seen = Set<String>()
        return segments.compactMap { seen.insert($0.speaker).inserted ? $0.speaker : nil }
    }
}
