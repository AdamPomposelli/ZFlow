import Foundation

/// Preset combinations of the three post-processing stages, so the common
/// trade-off between speed and output quality is one choice instead of three.
/// `custom` is not selectable: it is what the picker reports when the toggles
/// have been set to a combination no preset covers.
public enum PipelineMode: String, CaseIterable, Identifiable {
    case fast
    case normal
    case quality

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fast: return "Fast"
        case .normal: return "Normal"
        case .quality: return "Quality"
        }
    }

    public var summary: String {
        switch self {
        case .fast:
            return "No post-processing. The transcript is pasted exactly as the speech-to-text model returned it — one network call per dictation."
        case .normal:
            return "Cleanup and context inference run, without a screenshot. Context comes from the app name, window title, and selected text."
        case .quality:
            return "Everything runs, including a screenshot of the active window sent for context inference. Slowest and most expensive, most aware of what is on screen."
        }
    }

    public var postProcessingEnabled: Bool { self != .fast }
    public var contextInferenceEnabled: Bool { self != .fast }
    public var screenshotEnabled: Bool { self == .quality }

    /// The preset matching a set of stage toggles, or nil when they form a
    /// combination no preset covers. Deriving the mode from the toggles rather
    /// than storing it separately means the two can never disagree.
    public static func matching(
        postProcessingEnabled: Bool,
        contextInferenceEnabled: Bool,
        screenshotEnabled: Bool
    ) -> PipelineMode? {
        allCases.first { mode in
            mode.postProcessingEnabled == postProcessingEnabled
                && mode.contextInferenceEnabled == contextInferenceEnabled
                && mode.screenshotEnabled == screenshotEnabled
        }
    }
}
