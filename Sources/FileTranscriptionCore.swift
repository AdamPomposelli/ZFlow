import Foundation

/// Rules about which files may be dropped in, and what a transcription job
/// looks like while it runs.
///
/// Separate from the audio work so the decisions can be tested without a file
/// or a network: what we accept, what we refuse, and how a job reports itself.
public enum FileTranscriptionCore {
    /// Containers AVFoundation opens on macOS. Anything else is refused up
    /// front rather than failing several seconds later with a codec error.
    public static let allowedExtensions: Set<String> = [
        "wav", "wave", "mp3", "m4a", "aac", "caf", "aif", "aiff", "aifc",
        "flac", "mp4", "m4v", "mov", "mpga", "mp2"
    ]

    /// Past this, the read would take longer than anyone will wait, and the
    /// cloud path would be refused by the provider anyway.
    public static let maximumBytes = 800 * 1024 * 1024

    public enum Refusal: Equatable {
        case unsupportedType(String)
        case missing
        case empty
        case tooLarge(bytes: Int)

        public var message: String {
            switch self {
            case .unsupportedType(let ext):
                let named = ext.isEmpty ? "that file" : ".\(ext) files"
                return "ZFlow cannot read \(named). Try WAV, MP3, M4A, FLAC, or the audio from an MP4."
            case .missing:
                return "ZFlow could not find that file. It may have been moved or renamed."
            case .empty:
                return "That file is empty."
            case .tooLarge(let bytes):
                let gb = Double(bytes) / (1024 * 1024 * 1024)
                return String(format: "That file is %.1f GB. The limit is 800 MB.", gb)
            }
        }
    }

    /// `exists` is separate from the size, because a file that is not there
    /// and a file that is there but empty are different mistakes and deserve
    /// different sentences.
    public static func refusal(forName name: String, sizeInBytes: Int, exists: Bool = true) -> Refusal? {
        let ext = (name as NSString).pathExtension.lowercased()
        guard allowedExtensions.contains(ext) else { return .unsupportedType(ext) }
        guard exists else { return .missing }
        guard sizeInBytes > 0 else { return .empty }
        guard sizeInBytes <= maximumBytes else { return .tooLarge(bytes: sizeInBytes) }
        return nil
    }

    /// Where a job has got to.
    ///
    /// Transcribing an hour of audio takes minutes, which is far too long to
    /// hold an HTTP request open — so the drop starts a job and the front end
    /// asks how it is doing.
    public enum JobState: Equatable {
        case running(progress: Double)
        case finished(transcript: String)
        case failed(message: String)

        public var name: String {
            switch self {
            case .running: return "running"
            case .finished: return "finished"
            case .failed: return "failed"
            }
        }
    }

    public struct Job: Equatable {
        public let id: String
        public let fileName: String
        public var state: JobState
        public var engine: String
        public var audioSeconds: Double

        public init(
            id: String,
            fileName: String,
            state: JobState = .running(progress: 0),
            engine: String = "",
            audioSeconds: Double = 0
        ) {
            self.id = id
            self.fileName = fileName
            self.state = state
            self.engine = engine
            self.audioSeconds = audioSeconds
        }

        public var payload: [String: Any] {
            var json: [String: Any] = [
                "id": id,
                "fileName": fileName,
                "state": state.name,
                "engine": engine,
                "audioSeconds": audioSeconds
            ]
            switch state {
            case .running(let progress): json["progress"] = progress
            case .finished(let transcript): json["transcript"] = transcript
            case .failed(let message): json["error"] = message
            }
            return json
        }
    }
}
