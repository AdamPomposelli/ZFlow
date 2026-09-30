import Foundation

/// An error that can state itself briefly, for the recording overlay and menu
/// bar where only one line fits. The long form stays in `errorDescription`,
/// which is what the Run Log shows.
public protocol ShortDisplayableError {
    var shortDisplayMessage: String { get }
}

/// How long to wait for a transcription before giving up.
///
/// The budget has to scale with the recording, because both halves of the wait
/// grow with it: the upload carries ~32 KB per second of audio (~43 KB once
/// base64 encoded for providers that require JSON), and inference time is
/// roughly proportional to duration. A single fixed budget is therefore
/// generous for a three-second clip and too tight for a thirty-second one,
/// which shows up as timeouts that correlate with how long the user spoke
/// rather than with anything actually being wrong.
public enum TranscriptionTimeoutBudget {
    /// Budget for the request itself: connection setup, model queueing, and the
    /// provider's fixed overhead.
    public static let defaultBaseSeconds: TimeInterval = 20

    /// Extra budget per second of recorded audio. Sized for a slow uplink plus
    /// an unhurried ASR model, since overshooting only delays an error message
    /// while undershooting discards a transcript the provider did produce.
    public static let perAudioSecond: TimeInterval = 0.75

    /// Ceiling, so a hung connection still fails in bounded time.
    public static let maximumSeconds: TimeInterval = 300

    public static func seconds(
        baseSeconds: TimeInterval,
        audioDurationSeconds: TimeInterval?
    ) -> TimeInterval {
        let base = baseSeconds > 0 ? baseSeconds : defaultBaseSeconds
        guard let audioDurationSeconds, audioDurationSeconds > 0 else {
            return min(base, maximumSeconds)
        }
        return min(base + audioDurationSeconds * perAudioSecond, maximumSeconds)
    }
}

/// What was being waited on when the budget ran out. Carried on the error so
/// the Run Log can say why the wait was as long as it was, instead of naming a
/// number with no units of meaning attached.
public struct TranscriptionTimeoutReport: Equatable {
    public let timeoutSeconds: TimeInterval
    public let audioDurationSeconds: TimeInterval?
    public let uploadByteCount: Int64?
    public let host: String?
    public let usesJSONBase64: Bool
    public let model: String
    public let defaultsDomain: String?

    public init(
        timeoutSeconds: TimeInterval,
        audioDurationSeconds: TimeInterval?,
        uploadByteCount: Int64?,
        host: String?,
        usesJSONBase64: Bool,
        model: String,
        defaultsDomain: String?
    ) {
        self.timeoutSeconds = timeoutSeconds
        self.audioDurationSeconds = audioDurationSeconds
        self.uploadByteCount = uploadByteCount
        self.host = host
        self.usesJSONBase64 = usesJSONBase64
        self.model = model
        self.defaultsDomain = defaultsDomain
    }

    /// One line for the overlay. Names what timed out, not just that something did.
    public var shortMessage: String {
        guard let audioDurationSeconds, audioDurationSeconds > 0 else {
            return "\(provider) did not answer within \(formatted(timeoutSeconds))"
        }
        return "\(provider) did not answer within \(formatted(timeoutSeconds)) for \(formatted(audioDurationSeconds)) of audio"
    }

    /// The Run Log entry. Says what the app did, what it was waiting for, what
    /// it did NOT observe, and what the user can change — in that order,
    /// because "timed out" alone leaves every one of those open.
    public var detailedMessage: String {
        var lines: [String] = []

        lines.append(
            "Transcription timed out: \(AppName.displayName) stopped waiting after \(formatted(timeoutSeconds))."
        )

        lines.append(
            "This is \(AppName.displayName) giving up, not an error from the provider. \(provider) never sent a response, so the recording may well have been transcribed on their side — there is no way to tell from here."
        )

        var sent = "Sent: \(model)"
        if let audioDurationSeconds, audioDurationSeconds > 0 {
            sent += ", \(formatted(audioDurationSeconds)) of audio"
        }
        if let uploadByteCount, uploadByteCount > 0 {
            sent += " (\(formattedBytes(uploadByteCount))\(usesJSONBase64 ? " as base64 JSON" : " as a multipart upload"))"
        }
        lines.append(sent + ".")

        if let audioDurationSeconds, audioDurationSeconds > 0 {
            lines.append(
                "The limit scales with recording length: \(formatted(TranscriptionTimeoutBudget.defaultBaseSeconds)) plus \(formatted(TranscriptionTimeoutBudget.perAudioSecond)) per second of audio."
            )
        }

        lines.append("Common causes: a slow or busy provider, a slow upload, or an unusually long recording.")

        if let defaultsDomain {
            lines.append(
                "To wait longer, raise the base limit: defaults write \(defaultsDomain) transcription_timeout_seconds -float 60"
            )
        }

        return lines.joined(separator: "\n")
    }

    private var provider: String {
        host ?? "The provider"
    }

    private func formatted(_ seconds: TimeInterval) -> String {
        if seconds < 1 {
            return String(format: "%.2fs", seconds)
        }
        if seconds < 10 {
            let rounded = (seconds * 10).rounded() / 10
            return rounded == rounded.rounded()
                ? "\(Int(rounded))s"
                : String(format: "%.1fs", rounded)
        }
        return "\(Int(seconds.rounded()))s"
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        let megabytes = Double(bytes) / 1_048_576
        if megabytes >= 1 {
            return String(format: "%.1f MB", megabytes)
        }
        return "\(Int((Double(bytes) / 1024).rounded())) KB"
    }
}
