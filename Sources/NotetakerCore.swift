import Foundation

/// A recorded meeting and what came of it.
public struct MeetingNote: Codable, Equatable {
    public enum State: String, Codable {
        case recorded       // audio on disk, nothing done with it yet
        case transcribing
        case ready
        case failed
    }

    public var id: String
    public var title: String
    public var startedAt: Date
    public var durationSeconds: Double
    public var state: State
    /// The conversation, one speaker per line.
    public var transcript: String
    /// Segments behind that transcript, kept so the text can be rebuilt with
    /// different speaker names without transcribing again.
    public var segments: [StoredSegment]
    public var speakers: [String]
    public var summary: String
    public var errorMessage: String
    /// Which engine produced it, so a note says where it went.
    public var engine: String

    public struct StoredSegment: Codable, Equatable {
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

    public init(
        id: String,
        title: String,
        startedAt: Date,
        durationSeconds: Double = 0,
        state: State = .recorded,
        transcript: String = "",
        segments: [StoredSegment] = [],
        speakers: [String] = [],
        summary: String = "",
        errorMessage: String = "",
        engine: String = ""
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.state = state
        self.transcript = transcript
        self.segments = segments
        self.speakers = speakers
        self.summary = summary
        self.errorMessage = errorMessage
        self.engine = engine
    }
}

public enum NotetakerCore {
    /// The two tracks a meeting is recorded as.
    ///
    /// Splitting the recording this way is what makes "who said that" mostly
    /// free: your microphone is you, by definition, and everything the machine
    /// played is everyone else. Diarization then only has to separate the
    /// remote voices from each other.
    public static let micTrackFileName = "mic.wav"
    public static let systemTrackFileName = "system.wav"

    public static let youLabel = "You"
    public static let remoteLabel = "Them"

    /// A note id that is safe as a folder name. Generated here, never taken
    /// from the caller, so a crafted id cannot walk out of the notes folder.
    public static func newIdentifier(_ uuid: UUID = UUID()) -> String {
        uuid.uuidString
    }

    /// Whether an id is one we could have produced. Anything else is refused
    /// rather than joined onto a path.
    public static func isValidIdentifier(_ id: String) -> Bool {
        UUID(uuidString: id) != nil
    }

    /// The title a meeting gets before anyone renames it.
    public static func defaultTitle(startedAt: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "d MMMM 'at' HH:mm"
        return "Meeting on " + formatter.string(from: startedAt)
    }

    /// The title taken from what was actually said, once there is a transcript.
    ///
    /// The first thing anyone says in a meeting is usually what it is about,
    /// and a list of "Meeting on 3 October" tells you nothing a fortnight later.
    public static func suggestedTitle(from transcript: String, limit: Int = 60) -> String? {
        let firstSentence = transcript
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { ".!?".contains($0) })
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstSentence, firstSentence.count >= 12 else { return nil }
        guard firstSentence.count > limit else { return firstSentence }
        let clipped = firstSentence.prefix(limit)
        guard let lastSpace = clipped.lastIndex(of: " ") else { return String(clipped) + "…" }
        return String(clipped[..<lastSpace]) + "…"
    }

    /// How speakers are named in the finished transcript.
    public static func speakerName(forDiarizedIndex index: Int) -> String {
        "Speaker \(index + 1)"
    }
}
