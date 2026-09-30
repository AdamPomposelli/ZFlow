import Foundation

public struct ModelConfig {
    public let maxCompletionTokens: Int?
    public let reasoningEffort: String?
    public let includeReasoning: Bool?
    public let shouldStripThinkTags: Bool
}

public struct ModelConfiguration {
    public static let llmModels = [
        "openai/gpt-oss-20b",
        "openai/gpt-oss-120b",
        "openai/gpt-oss-safeguard-20b",
        "qwen/qwen3.6-27b",
        "groq/compound",
        "groq/compound-mini"
    ]

    // MARK: - Vision-capable models

    /// Models that accept image input. The context model must support vision for screenshot analysis to work.
    public static let visionModels = [
        "qwen/qwen3.6-27b"
    ]

    public static let transcriptionModels = [
        "whisper-large-v3",
        "whisper-large-v3-turbo"
    ]

    // MARK: - ZenMux catalog

    // ZenMux aggregates models from many providers behind one OpenAI-compatible
    // endpoint, so its catalog shares no IDs with Groq's. These lists populate
    // the model dropdowns when the configured base URL points at ZenMux; any
    // other ID can still be typed by hand.

    public static let zenmuxLLMModels = [
        "google/gemini-3.5-flash-lite",
        "qwen/qwen3-max",
        "google/gemini-3.5-flash",
        "anthropic/claude-haiku-4.5",
        "deepseek/deepseek-v3.2"
    ]

    /// ZenMux models that accept image input, for screenshot-based context.
    public static let zenmuxVisionModels = [
        "google/gemini-3.5-flash",
        "google/gemini-3.8-flash",
        "anthropic/claude-haiku-4.5",
        "qwen/qwen3-vl-plus"
    ]

    /// ZenMux does not proxy Groq's Whisper models; these are its own ASR IDs.
    public static let zenmuxTranscriptionModels = [
        "qwen/qwen3-asr-flash",
        "openai/gpt-transcribe",
        "x-ai/grok-voice-stt-1.0",
        "bytedance/doubao-seed-asr-2.0"
    ]

    // Defaults applied by the "Use ZenMux" button: a cheap, fast cleanup model,
    // a fallback from a different upstream provider so one outage does not take
    // both, and a vision model for screenshot-based context.
    public static let defaultZenMuxPostProcessingModel = "google/gemini-3.5-flash-lite"
    public static let defaultZenMuxPostProcessingFallbackModel = "qwen/qwen3-max"
    public static let defaultZenMuxContextModel = "google/gemini-3.5-flash"
    public static let defaultZenMuxTranscriptionModel = "qwen/qwen3-asr-flash"

    public static func llmModels(forBaseURL baseURL: String) -> [String] {
        TranscriptionProvider.isZenMux(baseURL: baseURL) ? zenmuxLLMModels : llmModels
    }

    public static func visionModels(forBaseURL baseURL: String) -> [String] {
        TranscriptionProvider.isZenMux(baseURL: baseURL) ? zenmuxVisionModels : visionModels
    }

    public static func transcriptionModels(forBaseURL baseURL: String) -> [String] {
        TranscriptionProvider.isZenMux(baseURL: baseURL) ? zenmuxTranscriptionModels : transcriptionModels
    }

    public static func config(for model: String) -> ModelConfig {
        var cleanModel = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        
        // Normalize providerless aliases
        if cleanModel == "qwen3-32b" { cleanModel = "qwen/qwen3-32b" }
        else if cleanModel == "qwen3.6-27b" { cleanModel = "qwen/qwen3.6-27b" }
        else if cleanModel == "gpt-oss-20b" { cleanModel = "openai/gpt-oss-20b" }
        else if cleanModel == "gpt-oss-120b" { cleanModel = "openai/gpt-oss-120b" }
        else if cleanModel == "gpt-oss-safeguard-20b" { cleanModel = "openai/gpt-oss-safeguard-20b" }
        
        if cleanModel == "openai/gpt-oss-20b" {
            return ModelConfig(
                maxCompletionTokens: 4096,
                reasoningEffort: "low",
                includeReasoning: false,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "openai/gpt-oss-120b" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "openai/gpt-oss-safeguard-20b" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "qwen/qwen3-32b" {
            // Model that requires sanitization of thought tags
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: true
            )
        } else if cleanModel == "qwen/qwen3.6-27b" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: "none",
                includeReasoning: false,
                shouldStripThinkTags: true
            )
        } else if cleanModel == "llama-3.1-8b-instant" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "llama-3.3-70b-versatile" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "meta-llama/llama-4-scout-17b-16e-instruct" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "meta-llama/llama-prompt-guard-2-22m" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "meta-llama/llama-prompt-guard-2-86m" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "allam-2-7b" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "canopylabs/orpheus-arabic-saudi" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "canopylabs/orpheus-v1-english" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "groq/compound" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "groq/compound-mini" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "whisper-large-v3" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "whisper-large-v3-turbo" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        }
        
        // Generic fallback for any model not explicitly listed above
        return ModelConfig(
            maxCompletionTokens: nil,
            reasoningEffort: nil,
            includeReasoning: nil,
            shouldStripThinkTags: false
        )
    }
    
    /// Utility method to remove <think>...</think> tags and everything inside them.
    /// This also handles unclosed tags gracefully (e.g. if the model runs out of tokens).
    public static func stripThinkTags(_ text: String) -> String {
        var cleaned = text
        
        // First, replace fully closed tags: <think>...</think>
        // We use a group with + to catch multiple consecutive think blocks.
        let closedRegexPattern = "^(?:\\s*<think>[\\s\\S]*?</think>)+"
        if let regex = try? NSRegularExpression(pattern: closedRegexPattern, options: []) {
            let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
            cleaned = regex.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: "")
        }
        
        // Next, if there is an unclosed <think> tag remaining (meaning it started thinking but got truncated),
        // we strip from the opening <think> tag to the very end of the string.
        let openRegexPattern = "^\\s*<think>[\\s\\S]*$"
        if let regex = try? NSRegularExpression(pattern: openRegexPattern, options: []) {
            let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
            cleaned = regex.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: "")
        }
        
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
