import Foundation

/// Where speech-to-text runs.
///
/// The cloud engine uploads the finished recording and waits; the local engine
/// feeds audio to Apple's on-device model while the user is still speaking, so
/// only the tail is left when the key comes up. Local needs no key, costs
/// nothing per hour, and sends no audio off the machine.
public enum TranscriptionEngine: String, CaseIterable, Identifiable {
    case cloud
    case local

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .cloud: return "Cloud provider"
        case .local: return "On-device (Apple)"
        }
    }

    public var summary: String {
        switch self {
        case .cloud:
            return "Uploads the recording to the configured provider after you stop speaking. Best accuracy on technical vocabulary; costs per hour and needs a network."
        case .local:
            return "Transcribes on this Mac while you speak, using Apple's on-device model. No API key, no per-hour cost, nothing leaves the machine. Needs macOS 26, and is generally less precise on jargon and code."
        }
    }

    public static func normalized(_ rawValue: String?) -> TranscriptionEngine {
        guard let rawValue else { return .cloud }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return TranscriptionEngine(rawValue: trimmed) ?? .cloud
    }

    /// Where a saved recording goes when it is transcribed again.
    public enum RetryRoute: Equatable {
        case onDevice
        case provider
        /// On-device was chosen and this Mac cannot do it. Refused, not
        /// rerouted: the recording stays here.
        case unavailable
    }

    /// Retrying goes where the first attempt went.
    ///
    /// It used to go to the provider unconditionally, whatever this said —
    /// so pressing Retry on a failed on-device dictation uploaded the
    /// recording that on-device had been chosen to keep here. A retry is the
    /// same request made again, not a different one.
    public func retryRoute(localSupported: Bool) -> RetryRoute {
        switch self {
        case .cloud: return .provider
        case .local: return localSupported ? .onDevice : .unavailable
        }
    }
}

/// A transcription that consumes audio as it is produced and yields a final
/// transcript when the input closes. Implemented by the provider WebSocket and
/// by the on-device analyzer, so the pipeline treats them the same.
protocol StreamingTranscriptionSession: AnyObject {
    func appendPCM16(_ data: Data)
    func commitAndAwaitFinal() async throws -> String
    func cancel()
}

/// Where transcript cleanup and Edit Mode run.
public enum PostProcessingEngine: String, CaseIterable, Identifiable {
    case cloud
    case local

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .cloud: return "Cloud provider"
        case .local: return "On-device (Apple)"
        }
    }

    public var summary: String {
        switch self {
        case .cloud:
            return "Sends the transcript to the post-processing model configured below. Strongest rewriting, and the only option that honours the fallback model."
        case .local:
            return "Cleans the transcript with Apple's on-device model. Nothing leaves the Mac and there is no per-token cost. Needs macOS 26 with Apple Intelligence enabled, and handles long or intricate rewrites less well than a frontier model."
        }
    }

    public static func normalized(_ rawValue: String?) -> PostProcessingEngine {
        guard let rawValue else { return .cloud }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return PostProcessingEngine(rawValue: trimmed) ?? .cloud
    }
}
