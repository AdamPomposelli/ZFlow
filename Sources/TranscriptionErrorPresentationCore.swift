import Foundation

enum TranscriptionErrorPresentationCore {
    /// Classifies transcription failures by locale-independent error codes
    /// before falling back to the system's localized description.
    static func message(for error: Error, isOnline: Bool) -> String {
        // An error that already knows how to state itself briefly wins: the
        // generic "Request timed out — try again" below throws away which
        // provider was waited on and for how much audio. Offline is not a
        // special case here — losing the connection surfaces as a URLError,
        // which is classified below, not as one of these.
        if let displayable = error as? ShortDisplayableError {
            return displayable.shortDisplayMessage
        }

        if let code = urlErrorCode(in: error) {
            switch code {
            case .networkConnectionLost:
                return "Connection lost — retry or try another network"
            case .notConnectedToInternet, .cannotConnectToHost,
                 .cannotFindHost, .dnsLookupFailed:
                return "No internet — check connection"
            case .timedOut:
                return isOnline
                    ? "Request timed out — try again"
                    : "No internet — check connection"
            default:
                break
            }
        }

        let lower = error.localizedDescription.lowercased()
        if lower.contains("timed out") || lower.contains("timeout") {
            return isOnline
                ? "Request timed out — try again"
                : "No internet — check connection"
        }
        if lower.contains("offline") || lower.contains("internet connection")
            || lower.contains("not connected") || lower.contains("network")
            || lower.contains("cannot find host") {
            return "No internet — check connection"
        }
        return error.localizedDescription
    }

    /// Prefixes `TranscriptionError.errorDescription` uses. A run whose status
    /// starts with one of these failed while transcribing, not while
    /// post-processing, so the Run Log can attribute it to the right step
    /// instead of showing a transcription failure under "Post-Process".
    private static let transcriptionStagePrefixes = [
        "Transcription timed out",
        "Transcription failed",
        "Submission failed",
        "Upload failed",
        "Polling failed",
        "Audio preparation failed",
        "Invalid provider URL"
    ]

    /// True when a stored pipeline status describes a failure of the
    /// transcription call rather than of post-processing.
    static func isTranscriptionStageFailure(status: String) -> Bool {
        let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("Error:") else { return false }
        let detail = trimmed
            .dropFirst("Error:".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return transcriptionStagePrefixes.contains { detail.hasPrefix($0) }
    }

    /// Finds a URL error in wrappers used by provider transports.
    private static func urlErrorCode(in error: Error) -> URLError.Code? {
        var current: Error? = error
        var depth = 0
        while let err = current, depth < 8 {
            if let urlError = err as? URLError {
                return urlError.code
            }
            let nsError = err as NSError
            if nsError.domain == NSURLErrorDomain {
                return URLError.Code(rawValue: nsError.code)
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? Error
            depth += 1
        }
        return nil
    }
}
