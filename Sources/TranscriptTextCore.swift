import Foundation
import os.log

private let transcriptTextLog = OSLog(
    subsystem: "com.zippy.zflow",
    category: "Transcription"
)

enum TranscriptionResponseParsingError: Error, Equatable {
    case invalidResponse
}

enum TranscriptionResponseParser {
    // Whisper can emit these stock phrases for silence or background noise.
    // Only suppress them when segment metadata independently reports a high
    // probability of no speech, which protects genuine short dictations.
    private static let hallucinationPhrases: Set<String> = [
        "thank you",
        "thank you for watching",
        "thank you very much",
        "thank you so much",
        "thanks for watching",
        "please subscribe",
        "like and subscribe",
        "subtitles by",
        "subtitles by the amara.org community",
        "you"
    ]

    // Tuned conservatively against roughly 500 quiet, noisy, and real-speech
    // samples to minimize the chance of filtering genuine short dictations.
    private static let hallucinationNoSpeechThreshold = 0.1

    static func parse(_ data: Data) throws -> String {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw TranscriptionResponseParsingError.invalidResponse
        }

        if let json = object as? [String: Any],
           let text = json["text"] as? String {
            if isHallucination(text: text, json: json) {
                return ""
            }
            return text
        }

        let plainText = String(data: data, encoding: .utf8) ?? ""
        let text = plainText
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw TranscriptionResponseParsingError.invalidResponse
        }

        return text
    }

    private static func isHallucination(text: String, json: [String: Any]) -> Bool {
        let normalized = text
            .lowercased()
            .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines))
        guard hallucinationPhrases.contains(normalized) else {
            return false
        }

        guard let segments = json["segments"] as? [[String: Any]] else {
            os_log(
                .info,
                log: transcriptTextLog,
                "Skipping hallucination filter for '%{public}@': provider response has no segments/no_speech metadata",
                normalized
            )
            return false
        }

        guard let noSpeechProb = segments.first?["no_speech_prob"] as? Double else {
            os_log(
                .info,
                log: transcriptTextLog,
                "Skipping hallucination filter for '%{public}@': provider response omitted no_speech_prob",
                normalized
            )
            return false
        }
        return noSpeechProb >= hallucinationNoSpeechThreshold
    }
}

enum TranscriptOutputSanitizer {
    /// Uppercase tokens the prompts use to fence their sections. A model that
    /// echoes one has leaked scaffolding, not produced speech, so these are
    /// removed from the edges of a response even when unbracketed.
    private static let promptMarkerTokens: Set<String> = [
        "RAW_TRANSCRIPTION",
        "CLEANED_TRANSCRIPTION",
        "TRANSCRIPTION",
        "TRANSCRIPT",
        "CONTEXT",
        "SELECTED_TEXT",
        "VOICE_COMMAND",
        "OUTPUT",
        "INSTRUCTIONS"
    ]

    /// A whole line that is only fence punctuation: `<<<`, `>>>`, ``` etc.
    private static let punctuationOnlyFence = try! NSRegularExpression(
        pattern: #"^[<>`~\-=_*\s]+$"#
    )

    /// A line that is a fence marker, optionally wrapped in angle brackets or
    /// backticks: `<<<RAW_TRANSCRIPTION`, `CLEANED_TRANSCRIPTION>>`, `[OUTPUT]`.
    private static let markerLine = try! NSRegularExpression(
        pattern: #"^\s*[<>`\[\(]*\s*([A-Z][A-Z0-9_]{2,})\s*[:>\]\)`]*\s*[<>`]*\s*$"#
    )

    /// A marker glued to the front of real text on the same line, which is how
    /// a leaked fence usually arrives: `<<<CLEANED_TRANSCRIPTION>> Actual text`.
    private static let leadingMarkerPrefix = try! NSRegularExpression(
        pattern: #"^\s*[<>`\[\(]{1,}\s*([A-Z][A-Z0-9_]{2,})\s*[:>\]\)`]*\s*"#
    )

    /// Removes prompt scaffolding a model echoed back around its answer.
    ///
    /// Only the edges are considered: an uppercase word in the middle of a
    /// sentence is far more likely to be something the user actually said.
    static func strippingPromptFences(_ value: String) -> String {
        var lines = value.components(separatedBy: .newlines)

        func isFenceLine(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return false }
            let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)

            if punctuationOnlyFence.firstMatch(in: trimmed, range: range) != nil {
                return true
            }
            guard let match = markerLine.firstMatch(in: trimmed, range: range),
                  let tokenRange = Range(match.range(at: 1), in: trimmed) else {
                return false
            }
            let token = String(trimmed[tokenRange])
            // Bracketed anything is scaffolding; bare words only when they are
            // one of the prompt's own section names.
            let isBracketed = trimmed.contains("<") || trimmed.contains(">")
                || trimmed.contains("`") || trimmed.contains("[")
            return isBracketed || promptMarkerTokens.contains(token)
        }

        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty || isFenceLine(first) {
            lines.removeFirst()
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty || isFenceLine(last) {
            lines.removeLast()
        }

        // A marker can also be glued to the start of the first real line.
        if var first = lines.first {
            let range = NSRange(first.startIndex..<first.endIndex, in: first)
            if let match = leadingMarkerPrefix.firstMatch(in: first, range: range),
               let tokenRange = Range(match.range(at: 1), in: first),
               let fullRange = Range(match.range, in: first) {
                let token = String(first[tokenRange])
                let remainder = String(first[fullRange.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                // Only when something is actually left, so a line that is just
                // a marker is not turned into an empty first line here.
                if !remainder.isEmpty && (promptMarkerTokens.contains(token) || first.hasPrefix("<")) {
                    first = remainder
                    lines[0] = first
                }
            }
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Verbatim translation deliberately preserves the cleanup prompt's EMPTY
    // sentinel because "empty" can be legitimate translated speech here.
    static func verbatimTranslation(_ value: String) -> String {
        var result = strippingPromptFences(value)
        guard !result.isEmpty else { return "" }
        if result.hasPrefix("\"") && result.hasSuffix("\"") && result.count > 1 {
            result.removeFirst()
            result.removeLast()
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    static func postProcessedTranscript(_ value: String) -> String {
        var result = strippingPromptFences(value)
        guard !result.isEmpty else { return "" }

        if result.hasPrefix("\"") && result.hasSuffix("\"") && result.count > 1 {
            result.removeFirst()
            result.removeLast()
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if result == "EMPTY" {
            return ""
        }

        return result
    }

    static func commandModeTranscript(_ value: String) -> String {
        strippingPromptFences(value)
    }

    static func appearsToHaveExecutedInstruction(
        rawTranscript: String,
        cleanedTranscript: String,
        outputLanguage: String
    ) -> Bool {
        guard outputLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }

        let rawTokens = significantTokens(in: rawTranscript)
        let cleanedTokens = significantTokens(in: cleanedTranscript)
        guard !rawTokens.isEmpty, !cleanedTokens.isEmpty else { return false }

        let instructionMarkers: Set<String> = [
            "ask", "answer", "compose", "create", "draft", "email", "generate", "make",
            "message", "prompt", "reply", "respond", "response", "summarize", "tell",
            "translate", "write", "claude", "chatgpt", "ai", "llm"
        ]
        let rawMarkers = rawTokens.intersection(instructionMarkers)
        guard !rawMarkers.isEmpty else { return false }

        let preservedMarkers = rawMarkers.intersection(cleanedTokens)
        let overlap = rawTokens.intersection(cleanedTokens)
        let overlapRatio = Double(overlap.count) / Double(max(rawTokens.count, 1))
        let assistantPreamblePattern = #"(?i)^\s*(sure|certainly|absolutely|here(?:'s| is)|i(?:'d| would) be happy to|i can)\b"#
        let cleanedHasAssistantPreamble = cleanedTranscript.range(
            of: assistantPreamblePattern,
            options: .regularExpression
        ) != nil
        let rawHasSamePreamble = rawTranscript.range(
            of: assistantPreamblePattern,
            options: .regularExpression
        ) != nil

        return (cleanedHasAssistantPreamble && !rawHasSamePreamble)
            || (preservedMarkers.isEmpty && overlapRatio < 0.35)
    }

    private static func significantTokens(in text: String) -> Set<String> {
        let stopWords: Set<String> = [
            "a", "an", "and", "are", "as", "at", "be", "but", "by", "can", "could",
            "for", "from", "had", "has", "have", "he", "her", "him", "his", "i", "if",
            "in", "into", "is", "it", "its", "just", "me", "my", "of", "on", "or", "our",
            "please", "she", "so", "that", "the", "their", "them", "then", "there", "this",
            "to", "um", "uh", "was", "we", "were", "what", "when", "where", "who", "with",
            "would", "you", "your"
        ]

        let normalized = text.lowercased()
        let parts = normalized.split { character in
            !character.isLetter && !character.isNumber
        }

        return Set(parts.map(String.init).filter { token in
            token.count > 1 && !stopWords.contains(token)
        })
    }
}
