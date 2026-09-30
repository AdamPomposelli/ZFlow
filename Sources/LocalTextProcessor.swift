import Foundation
import FoundationModels
import os.log

private let localModelLog = OSLog(
    subsystem: "com.zippy.zflow",
    category: "LocalTextProcessing"
)

/// Transcript cleanup on Apple's on-device language model.
///
/// The counterpart to `LocalSpeechTranscriber`: with both selected, a dictation
/// never leaves the Mac. Requires macOS 26 with Apple Intelligence turned on,
/// which is a user decision in System Settings — `availability` reports exactly
/// which of those is missing so the UI can say so rather than just failing.
@available(macOS 26.0, *)
enum LocalTextProcessor {
    /// Why the on-device model cannot be used right now, or nil when it can.
    enum Unavailability: Equatable {
        case appleIntelligenceNotEnabled
        case modelNotReady
        case deviceNotEligible
        case other(String)

        var message: String {
            switch self {
            case .appleIntelligenceNotEnabled:
                return "Apple Intelligence is turned off. Enable it in System Settings ▸ Apple Intelligence & Siri to use on-device cleanup."
            case .modelNotReady:
                return "The on-device model is still downloading. Cleanup will use it once macOS finishes preparing it."
            case .deviceNotEligible:
                return "This Mac does not support Apple Intelligence, so on-device cleanup is unavailable."
            case .other(let detail):
                return "On-device cleanup is unavailable: \(detail)"
            }
        }
    }

    static var unavailability: Unavailability? {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled:
                return .appleIntelligenceNotEnabled
            case .modelNotReady:
                return .modelNotReady
            case .deviceNotEligible:
                return .deviceNotEligible
            @unknown default:
                return .other(String(describing: reason))
            }
        @unknown default:
            return .other("unrecognized availability state")
        }
    }

    static var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    enum LocalProcessingError: LocalizedError, ShortDisplayableError {
        case unavailable(Unavailability)
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .unavailable(let reason): return reason.message
            case .emptyResponse: return "The on-device model returned nothing for this transcript."
            }
        }

        var shortDisplayMessage: String {
            switch self {
            case .unavailable(.appleIntelligenceNotEnabled): return "Apple Intelligence is turned off"
            case .unavailable(.modelNotReady): return "On-device model still downloading"
            case .unavailable(.deviceNotEligible): return "This Mac has no Apple Intelligence"
            case .unavailable: return "On-device cleanup unavailable"
            case .emptyResponse: return "On-device cleanup returned nothing"
            }
        }
    }

    /// Cleans `transcript` using the same prompt the provider path builds, so
    /// switching engines does not change the instructions.
    static func postProcess(
        transcript: String,
        contextSummary: String,
        customVocabulary: String,
        customSystemPrompt: String,
        outputLanguage: String
    ) async throws -> PostProcessingResult {
        if let unavailability { throw LocalProcessingError.unavailable(unavailability) }

        let systemPrompt = CleanupPromptBuilder.systemPrompt(
            defaultSystemPrompt: PostProcessingService.defaultSystemPrompt,
            customSystemPrompt: customSystemPrompt,
            outputLanguage: outputLanguage,
            vocabularyText: normalizedVocabulary(customVocabulary)
        )
        let userMessage = CleanupPromptBuilder.userMessage(
            transcript: transcript,
            contextSummary: contextSummary
        )
        let promptForDisplay = CleanupPromptBuilder.promptForDisplay(
            model: "apple/on-device",
            systemPrompt: systemPrompt,
            userMessage: userMessage
        )

        let session = LanguageModelSession(instructions: systemPrompt)
        // Deterministic: dictation cleanup should not reword the same sentence
        // differently on a retry.
        let options = GenerationOptions(temperature: 0)

        do {
            let response = try await session.respond(to: userMessage, options: options)
            let cleaned = TranscriptOutputSanitizer.postProcessedTranscript(response.content)
            return PostProcessingResult(transcript: cleaned, prompt: promptForDisplay)
        } catch {
            os_log(
                .error,
                log: localModelLog,
                "On-device cleanup failed: %{public}@",
                error.localizedDescription
            )
            throw error
        }
    }

    /// Sends a bare prompt to the on-device model. Used by the correction
    /// adjudicator, which asks a yes/no question rather than cleaning text.
    static func adjudicate(prompt: String) async throws -> String {
        if let unavailability { throw LocalProcessingError.unavailable(unavailability) }
        let session = LanguageModelSession()
        let response = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0))
        return response.content
    }

    /// Mirrors PostProcessingService's splitting of the vocabulary field so the
    /// same terms reach both engines.
    private static func normalizedVocabulary(_ raw: String) -> String {
        raw
            .split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}
