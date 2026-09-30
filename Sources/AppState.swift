import Foundation
import Combine
import AppKit
import AVFoundation
import ServiceManagement
import ApplicationServices
import ScreenCaptureKit
import Carbon
import os.log
private let recordingLog = OSLog(subsystem: "com.zippy.zflow", category: "Recording")

struct VoiceMacro: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var command: String
    var payload: String
}

struct PrecomputedMacro {
    let original: VoiceMacro
    let normalizedCommand: String
}

/// Settings tabs, in the order they are shown.
///
/// Grouped by how often a setting is touched and by what it affects, rather
/// than by which part of the code owns it: everyday dictation first, then the
/// engines behind it, then what happens to the text, then looks, then the
/// dials most people never open, and history last.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case engines
    case postProcessing
    case appearance
    case advanced
    case history
    case debug

    var id: String { rawValue }

    static var visibleCases: [SettingsTab] {
        allCases.filter { tab in
            tab != .debug || AppBuild.isDevBundle
        }
    }

    var title: String {
        switch self {
        case .general: return "General"
        case .engines: return "Engines"
        case .postProcessing: return "Post-Processing"
        case .appearance: return "Appearance"
        case .advanced: return "Advanced"
        case .history: return "History"
        case .debug: return "Debug"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .engines: return "cpu"
        case .postProcessing: return "wand.and.sparkles"
        case .appearance: return "paintbrush"
        case .advanced: return "slider.horizontal.3"
        case .history: return "clock.arrow.circlepath"
        case .debug: return "wrench.and.screwdriver"
        }
    }
}

enum AppBuild {
    static var isDevBundle: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) == "ZFlow Dev"
    }
}

private struct PreservedPasteboardEntry {
    let type: NSPasteboard.PasteboardType
    let value: Value

    enum Value {
        case string(String)
        case propertyList(Any)
        case data(Data)
    }
}

private struct PreservedPasteboardItem {
    let entries: [PreservedPasteboardEntry]

    init(item: NSPasteboardItem) {
        self.entries = item.types.compactMap { type in
            if let string = item.string(forType: type) {
                return PreservedPasteboardEntry(type: type, value: .string(string))
            }
            if let propertyList = item.propertyList(forType: type) {
                return PreservedPasteboardEntry(type: type, value: .propertyList(propertyList))
            }
            if let data = item.data(forType: type) {
                return PreservedPasteboardEntry(type: type, value: .data(data))
            }
            return nil
        }
    }

    func makePasteboardItem() -> NSPasteboardItem {
        let item = NSPasteboardItem()
        for entry in entries {
            switch entry.value {
            case .string(let string):
                item.setString(string, forType: entry.type)
            case .propertyList(let propertyList):
                item.setPropertyList(propertyList, forType: entry.type)
            case .data(let data):
                item.setData(data, forType: entry.type)
            }
        }
        return item
    }
}

private struct PreservedPasteboardSnapshot {
    let items: [PreservedPasteboardItem]

    init(pasteboard: NSPasteboard) {
        self.items = (pasteboard.pasteboardItems ?? []).map(PreservedPasteboardItem.init)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        _ = pasteboard.writeObjects(items.map { $0.makePasteboardItem() })
    }
}

private struct PendingClipboardRestore {
    let snapshot: PreservedPasteboardSnapshot
    let expectedChangeCount: Int
    let writtenTranscript: String
}

private struct TranscriptCommandParsingResult {
    let transcript: String
    let shouldPressEnterAfterPaste: Bool
}

private enum CommandInvocation: String {
    case automatic
    case manual
}

private enum SessionIntent {
    case dictation
    case command(invocation: CommandInvocation, selectedText: String)

    var isCommandMode: Bool {
        switch self {
        case .dictation:
            return false
        case .command:
            return true
        }
    }

    var persistedIntent: PipelineHistoryItemIntent {
        switch self {
        case .dictation:
            return .dictation
        case .command(let invocation, _):
            switch invocation {
            case .automatic:
                return .commandAutomatic
            case .manual:
                return .commandManual
            }
        }
    }

    var persistedSelectedText: String? {
        switch self {
        case .dictation:
            return nil
        case .command(_, let selectedText):
            return selectedText
        }
    }

    var isManualCommand: Bool {
        switch self {
        case .command(invocation: .manual, _):
            return true
        default:
            return false
        }
    }

    static func fromPersisted(intent: PipelineHistoryItemIntent, selectedText: String?) -> SessionIntent {
        if intent == .commandAutomatic, let selectedText {
            return .command(invocation: .automatic, selectedText: selectedText)
        }
        if intent == .commandManual, let selectedText {
            return .command(invocation: .manual, selectedText: selectedText)
        }
        return .dictation
    }
}

final class AppState: ObservableObject, @unchecked Sendable {
    private enum ActiveAudioInterruption {
        case muted(previouslyMuted: Bool)
    }

    private let apiKeyStorageKey = "groq_api_key"
    private let apiBaseURLStorageKey = "api_base_url"
    private let transcriptionModelStorageKey = "transcription_model"
    private let transcriptionAPIURLStorageKey = "transcription_api_url"
    private let transcriptionAPIKeyStorageKey = "transcription_api_key"
    private let postProcessingModelStorageKey = "post_processing_model"
    private let postProcessingFallbackModelStorageKey = "post_processing_fallback_model"
    private let contextModelStorageKey = "context_model"
    private let holdShortcutStorageKey = "hold_shortcut"
    private let toggleShortcutStorageKey = "toggle_shortcut"
    private let copyAgainShortcutStorageKey = "copy_again_shortcut"
    private let savedHoldCustomShortcutStorageKey = "saved_hold_custom_shortcut"
    private let savedToggleCustomShortcutStorageKey = "saved_toggle_custom_shortcut"
    private let savedCopyAgainCustomShortcutStorageKey = "saved_copy_again_custom_shortcut"
    private let customVocabularyStorageKey = "custom_vocabulary"
    private let transcriptionLanguageStorageKey = "transcription_language"
    private let selectedMicrophoneStorageKey = "selected_microphone_id"
    private let customSystemPromptStorageKey = "custom_system_prompt"
    private let customContextPromptStorageKey = "custom_context_prompt"
    private let instructionExecutionGuardEnabledStorageKey = "instruction_execution_guard_enabled"
    private let customSystemPromptLastModifiedStorageKey = "custom_system_prompt_last_modified"
    private let customContextPromptLastModifiedStorageKey = "custom_context_prompt_last_modified"
    private let contextScreenshotMaxDimensionStorageKey = "context_screenshot_max_dimension"
    private let notetakerEngineStorageKey = "notetaker_engine"
    private let contextScreenshotEnabledStorageKey = "context_screenshot_enabled"
    private let postProcessingEnabledStorageKey = "post_processing_enabled"
    private let contextInferenceEnabledStorageKey = "context_inference_enabled"
    private let transcriptionRequestFormatStorageKey = "transcription_request_format"
    private let transcriptionEngineStorageKey = "transcription_engine"
    private let postProcessingEngineStorageKey = "post_processing_engine"
    private let learnedCorrectionsStorageKey = "learned_corrections"
    private let learnedCorrectionsEnabledStorageKey = "learned_corrections_enabled"
    private let correctionAdjudicationEnabledStorageKey = "correction_adjudication_enabled"
    private let shortcutStartDelayStorageKey = "shortcut_start_delay"
    private let preserveClipboardStorageKey = "preserve_clipboard"
    private let preserveExactWordingStorageKey = "preserve_exact_wording"
    private let keepDictationInClipboardHistoryStorageKey = "keep_dictation_in_clipboard_history"
    private let pressEnterVoiceCommandStorageKey = "press_enter_voice_command_enabled"
    private let alertSoundsEnabledStorageKey = "alert_sounds_enabled"
    private let soundVolumeStorageKey = "sound_volume"
    private let voiceMacrosStorageKey = "voice_macros"
    private let commandModeEnabledStorageKey = "command_mode_enabled"
    private let commandModeStyleStorageKey = "command_mode_style"
    private let commandModeManualModifierStorageKey = "command_mode_manual_modifier"
    private let outputLanguageStorageKey = "output_language"
    private let realtimeStreamingEnabledStorageKey = "realtime_streaming_enabled"
    private let realtimeStreamingModelStorageKey = "realtime_streaming_model"
    private let dictationAudioInterruptionEnabledStorageKey = "dictation_audio_interruption_enabled"
    private let pasteAfterShortcutReleaseDelay: TimeInterval = 0.03
    private let pressEnterAfterPasteDelay: TimeInterval = 0.08
    private let clipboardRestoreDelay: TimeInterval = 1.0
    let maxPipelineHistoryCount = 20
    static let defaultContextScreenshotMaxDimension = Int(AppContextService.defaultScreenshotMaxDimension)
    static let contextScreenshotDimensionOptions = [1024, 768, 640, 512]
    static let defaultTranscriptionModel = "whisper-large-v3"
    static let transcriptionLanguageOptions: [(code: String, name: String)] = [
        ("", "Auto-detect"),
        ("en", "English"),
        ("es", "Spanish"),
        ("fr", "French"),
        ("de", "German"),
        ("it", "Italian"),
        ("pt", "Portuguese"),
        ("nl", "Dutch"),
        ("ru", "Russian"),
        ("ja", "Japanese"),
        ("ko", "Korean"),
        ("zh", "Chinese"),
        ("ar", "Arabic"),
        ("hi", "Hindi"),
        ("tr", "Turkish"),
        ("pl", "Polish"),
        ("uk", "Ukrainian"),
        ("sv", "Swedish"),
        ("no", "Norwegian"),
        ("da", "Danish"),
        ("fi", "Finnish"),
        ("cs", "Czech"),
        ("el", "Greek"),
        ("he", "Hebrew"),
        ("vi", "Vietnamese"),
        ("th", "Thai"),
        ("id", "Indonesian"),
        ("ro", "Romanian"),
        ("hu", "Hungarian"),
        ("ca", "Catalan")
    ]
    static let defaultPostProcessingModel = "openai/gpt-oss-20b"
    static let defaultPostProcessingFallbackModel = "qwen/qwen3.6-27b"
    static let defaultContextModel = "qwen/qwen3.6-27b"
    private static let deprecatedDefaultPostProcessingFallbackModel = "meta-llama/llama-4-scout-17b-16e-instruct"
    private static let deprecatedDefaultContextModel = "meta-llama/llama-4-scout-17b-16e-instruct"
    private static let trailingPressEnterCommandPattern = try! NSRegularExpression(
        pattern: #"(?i)(?:^|[ \t\r\n,;:\-]+)press[ \t\r\n]+enter[\s\p{P}]*$"#
    )

    @Published var hasCompletedSetup: Bool {
        didSet {
            UserDefaults.standard.set(hasCompletedSetup, forKey: "hasCompletedSetup")
        }
    }

    @Published var apiKey: String {
        didSet {
            persistAPIKey(apiKey)
            rebuildContextService()
        }
    }

    @Published var apiBaseURL: String {
        didSet {
            persistAPIBaseURL(apiBaseURL)
            rebuildContextService()
        }
    }

    @Published var transcriptionAPIURL: String {
        didSet {
            persistOptionalAPIValue(transcriptionAPIURL, account: transcriptionAPIURLStorageKey)
        }
    }

    @Published var transcriptionAPIKey: String {
        didSet {
            persistOptionalAPIValue(transcriptionAPIKey, account: transcriptionAPIKeyStorageKey)
        }
    }

    @Published var transcriptionModel: String {
        didSet {
            UserDefaults.standard.set(transcriptionModel, forKey: transcriptionModelStorageKey)
        }
    }

    @Published var postProcessingModel: String {
        didSet {
            UserDefaults.standard.set(postProcessingModel, forKey: postProcessingModelStorageKey)
        }
    }

    @Published var postProcessingFallbackModel: String {
        didSet {
            UserDefaults.standard.set(postProcessingFallbackModel, forKey: postProcessingFallbackModelStorageKey)
        }
    }

    @Published var contextModel: String {
        didSet {
            UserDefaults.standard.set(contextModel, forKey: contextModelStorageKey)
            rebuildContextService()
        }
    }

    @Published var holdShortcut: ShortcutBinding {
        didSet {
            persistShortcut(holdShortcut, key: holdShortcutStorageKey)
            restartHotkeyMonitoring()
        }
    }

    @Published var toggleShortcut: ShortcutBinding {
        didSet {
            persistShortcut(toggleShortcut, key: toggleShortcutStorageKey)
            restartHotkeyMonitoring()
        }
    }

    @Published var copyAgainShortcut: ShortcutBinding {
        didSet {
            persistShortcut(copyAgainShortcut, key: copyAgainShortcutStorageKey)
            restartHotkeyMonitoring()
        }
    }

    @Published private(set) var savedHoldCustomShortcut: ShortcutBinding? {
        didSet {
            persistOptionalShortcut(savedHoldCustomShortcut, key: savedHoldCustomShortcutStorageKey)
        }
    }

    @Published private(set) var savedToggleCustomShortcut: ShortcutBinding? {
        didSet {
            persistOptionalShortcut(savedToggleCustomShortcut, key: savedToggleCustomShortcutStorageKey)
        }
    }

    @Published private(set) var savedCopyAgainCustomShortcut: ShortcutBinding? {
        didSet {
            persistOptionalShortcut(savedCopyAgainCustomShortcut, key: savedCopyAgainCustomShortcutStorageKey)
        }
    }

    @Published var isCommandModeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isCommandModeEnabled, forKey: commandModeEnabledStorageKey)
            restartHotkeyMonitoring()
        }
    }

    @Published var commandModeStyle: CommandModeStyle {
        didSet {
            UserDefaults.standard.set(commandModeStyle.rawValue, forKey: commandModeStyleStorageKey)
            restartHotkeyMonitoring()
        }
    }

    @Published private(set) var commandModeManualModifier: CommandModeManualModifier {
        didSet {
            UserDefaults.standard.set(commandModeManualModifier.rawValue, forKey: commandModeManualModifierStorageKey)
            restartHotkeyMonitoring()
        }
    }

    @Published var customVocabulary: String {
        didSet {
            UserDefaults.standard.set(customVocabulary, forKey: customVocabularyStorageKey)
        }
    }

    @Published var transcriptionLanguage: String {
        didSet {
            let normalized = Self.normalizeTranscriptionLanguage(transcriptionLanguage)
            if normalized != transcriptionLanguage {
                transcriptionLanguage = normalized
                return
            }
            UserDefaults.standard.set(normalized, forKey: transcriptionLanguageStorageKey)
        }
    }

    @Published var customSystemPrompt: String {
        didSet {
            UserDefaults.standard.set(customSystemPrompt, forKey: customSystemPromptStorageKey)
        }
    }

    @Published var customContextPrompt: String {
        didSet {
            UserDefaults.standard.set(customContextPrompt, forKey: customContextPromptStorageKey)
            rebuildContextService()
        }
    }

    @Published var instructionExecutionGuardEnabled: Bool {
        didSet {
            UserDefaults.standard.set(
                instructionExecutionGuardEnabled,
                forKey: instructionExecutionGuardEnabledStorageKey
            )
        }
    }

    @Published var postProcessingEnabled: Bool {
        didSet {
            UserDefaults.standard.set(postProcessingEnabled, forKey: postProcessingEnabledStorageKey)
        }
    }

    @Published var contextInferenceEnabled: Bool {
        didSet {
            UserDefaults.standard.set(contextInferenceEnabled, forKey: contextInferenceEnabledStorageKey)
            rebuildContextService()
        }
    }

    /// Which engine transcribes a recorded meeting.
    ///
    /// On-device by default, and deliberately separate from the dictation
    /// engine: a meeting is long, it is other people's voices, and sending it
    /// somewhere should be its own decision.
    @Published var notetakerEngine: TranscriptionEngine {
        didSet {
            UserDefaults.standard.set(notetakerEngine.rawValue, forKey: notetakerEngineStorageKey)
        }
    }

    @Published var contextScreenshotEnabled: Bool {
        didSet {
            UserDefaults.standard.set(contextScreenshotEnabled, forKey: contextScreenshotEnabledStorageKey)
            rebuildContextService()
            // Asked for here, and only here. Turning this on is the moment the
            // app first has a reason to record the screen, so that is when
            // macOS should be asking — not at launch, about something the user
            // has not chosen to do.
            if contextScreenshotEnabled && !oldValue {
                requestScreenCapturePermission()
            } else if !contextScreenshotEnabled {
                // Stop reporting a permission nothing needs any more.
                hasScreenRecordingPermission = false
                startAccessibilityPolling()
            }
        }
    }

    /// Words the user has respelled by hand after a paste. Applied to every
    /// later transcript so the same mishearing is fixed automatically.
    @Published var learnedCorrections: [WordCorrection] {
        didSet {
            guard let data = try? JSONEncoder().encode(learnedCorrections) else { return }
            UserDefaults.standard.set(data, forKey: learnedCorrectionsStorageKey)
        }
    }

    @Published var learnedCorrectionsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(
                learnedCorrectionsEnabled,
                forKey: learnedCorrectionsEnabledStorageKey
            )
            if !learnedCorrectionsEnabled {
                correctionWatcher.stop()
            }
        }
    }

    /// Ask the cleanup model when the rules cannot tell. Off by default: it is
    /// the one part of this feature that sends text off the machine, unless the
    /// cleanup engine is the on-device one.
    @Published var correctionAdjudicationEnabled: Bool {
        didSet {
            UserDefaults.standard.set(
                correctionAdjudicationEnabled,
                forKey: correctionAdjudicationEnabledStorageKey
            )
        }
    }

    @Published var postProcessingEngine: PostProcessingEngine {
        didSet {
            UserDefaults.standard.set(postProcessingEngine.rawValue, forKey: postProcessingEngineStorageKey)
        }
    }

    @Published var transcriptionEngine: TranscriptionEngine {
        didSet {
            UserDefaults.standard.set(transcriptionEngine.rawValue, forKey: transcriptionEngineStorageKey)
        }
    }

    @Published var transcriptionRequestFormat: TranscriptionRequestFormat {
        didSet {
            UserDefaults.standard.set(
                transcriptionRequestFormat.rawValue,
                forKey: transcriptionRequestFormatStorageKey
            )
        }
    }

    @Published var contextScreenshotMaxDimension: Int {
        didSet {
            let normalizedDimension = Self.normalizedContextScreenshotMaxDimension(contextScreenshotMaxDimension)
            if normalizedDimension != contextScreenshotMaxDimension {
                contextScreenshotMaxDimension = normalizedDimension
            }
            UserDefaults.standard.set(contextScreenshotMaxDimension, forKey: contextScreenshotMaxDimensionStorageKey)
            rebuildContextService()
        }
    }

    @Published var customSystemPromptLastModified: String {
        didSet {
            UserDefaults.standard.set(customSystemPromptLastModified, forKey: customSystemPromptLastModifiedStorageKey)
        }
    }

    @Published var customContextPromptLastModified: String {
        didSet {
            UserDefaults.standard.set(customContextPromptLastModified, forKey: customContextPromptLastModifiedStorageKey)
        }
    }

    @Published var outputLanguage: String {
        didSet {
            UserDefaults.standard.set(outputLanguage, forKey: outputLanguageStorageKey)
        }
    }

    @Published var shortcutStartDelay: TimeInterval {
        didSet {
            UserDefaults.standard.set(shortcutStartDelay, forKey: shortcutStartDelayStorageKey)
        }
    }

    /// Stream audio to the transcription backend during recording via the
    /// OpenAI Realtime WebSocket. Reduces wall-clock latency between "stop"
    /// and text-ready because most of the transcription work happens while
    /// the user is still speaking.
    @Published var realtimeStreamingEnabled: Bool {
        didSet {
            UserDefaults.standard.set(realtimeStreamingEnabled, forKey: realtimeStreamingEnabledStorageKey)
        }
    }

    /// Model ID the realtime WebSocket should transcribe with. Empty means
    /// "use the server's default".
    @Published var realtimeStreamingModel: String {
        didSet {
            UserDefaults.standard.set(realtimeStreamingModel, forKey: realtimeStreamingModelStorageKey)
        }
    }

    @Published var dictationAudioInterruptionEnabled: Bool {
        didSet {
            UserDefaults.standard.set(
                dictationAudioInterruptionEnabled,
                forKey: dictationAudioInterruptionEnabledStorageKey
            )
        }
    }

    @Published var preserveClipboard: Bool {
        didSet {
            UserDefaults.standard.set(preserveClipboard, forKey: preserveClipboardStorageKey)
        }
    }

    @Published var preserveExactWording: Bool {
        didSet {
            UserDefaults.standard.set(preserveExactWording, forKey: preserveExactWordingStorageKey)
        }
    }

    @Published var keepDictationInClipboardHistory: Bool {
        didSet {
            UserDefaults.standard.set(keepDictationInClipboardHistory, forKey: keepDictationInClipboardHistoryStorageKey)
        }
    }

    @Published var isPressEnterVoiceCommandEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isPressEnterVoiceCommandEnabled, forKey: pressEnterVoiceCommandStorageKey)
        }
    }

    @Published var alertSoundsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(alertSoundsEnabled, forKey: alertSoundsEnabledStorageKey)
        }
    }

    @Published var soundVolume: Float {
        didSet {
            UserDefaults.standard.set(soundVolume, forKey: soundVolumeStorageKey)
        }
    }

    private var precomputedMacros: [PrecomputedMacro] = []

    @Published var voiceMacros: [VoiceMacro] = [] {
        didSet {
            if let data = try? JSONEncoder().encode(voiceMacros) {
                UserDefaults.standard.set(data, forKey: voiceMacrosStorageKey)
            }
            precomputeMacros()
        }
    }

    @Published var isRecording = false {
        didSet {
            guard oldValue != isRecording else { return }
            AppState.writeRecordingStateFlag(isRecording)
        }
    }
    @Published var isTranscribing = false
    @Published var retryingItemIDs: Set<UUID> = []
    @Published var lastTranscript: String = ""
    @Published var errorMessage: String?
    @Published var statusText: String = "Ready"
    @Published var hasAccessibility = false
    @Published var hotkeyMonitoringErrorMessage: String?
    @Published var isDebugOverlayActive = false
    @Published var selectedSettingsTab: SettingsTab? = .general
    @Published var pipelineHistory: [PipelineHistoryItem] = []
    @Published var debugStatusMessage = "Idle"
    @Published var debugShowsUpdateReminderAfterDictation = false
    @Published var lastRawTranscript = ""
    @Published var lastPostProcessedTranscript = ""
    @Published var lastPostProcessingPrompt = ""
    @Published var lastContextSummary = ""
    @Published var lastPostProcessingStatus = ""
    @Published var lastContextScreenshotDataURL: String? = nil
    @Published var lastContextScreenshotStatus = "No screenshot"
    @Published var lastContextAppName: String = ""
    @Published var lastContextBundleIdentifier: String = ""
    @Published var lastContextWindowTitle: String = ""
    @Published var lastContextSelectedText: String = ""
    @Published var lastContextLLMPrompt: String = ""
    @Published var hasScreenRecordingPermission = false
    /// Microphone access. Without it the app cannot do the one thing it is
    /// for, so it is tracked and surfaced exactly like the other two rather
    /// than only failing at the moment someone tries to dictate.
    @Published var hasMicrophonePermission = false
    @Published var launchAtLogin: Bool {
        didSet { setLaunchAtLogin(launchAtLogin) }
    }

    @Published var selectedMicrophoneID: String {
        didSet {
            UserDefaults.standard.set(selectedMicrophoneID, forKey: selectedMicrophoneStorageKey)
        }
    }
    @Published var availableMicrophones: [AudioDevice] = []

    let audioRecorder = AudioRecorder()
    let hotkeyManager = HotkeyManager()
    let overlayManager = RecordingOverlayManager()
    private var accessibilityTimer: Timer?
    private var audioLevelCancellable: AnyCancellable?
    private var debugOverlayTimer: Timer?
    private var recordingInitializationTimer: DispatchSourceTimer?
    private var transcriptionTask: Task<Void, Never>?
    private var transcribingAudioFileName: String?
    private var contextService: AppContextService
    private var contextCaptureTask: Task<AppContext?, Never>?
    private let correctionWatcher = CorrectionWatcher()
    private var capturedContext: AppContext?
    private var hasShownScreenshotPermissionAlert = false
    private var audioDeviceObservers: [NSObjectProtocol] = []
    private var needsMicrophoneRefreshAfterRecording = false
    private let pipelineHistoryStore = PipelineHistoryStore()
    private let shortcutSessionController = DictationShortcutSessionController()
    private var activeRecordingTriggerMode: RecordingTriggerMode?
    private var currentSessionIntent: SessionIntent = .dictation
    private var pendingSelectionSnapshot: AppSelectionSnapshot?
    private var pendingManualCommandInvocation = false
    private var pendingShortcutStartTask: Task<Void, Never>?
    private var pendingShortcutStartMode: RecordingTriggerMode?
    private var realtimeService: (any StreamingTranscriptionSession)?
    private var automaticTerminationDisabled = false
    private var activeAudioInterruption: ActiveAudioInterruption?
    private var pendingOverlayDismissToken: UUID?
    private var shouldMonitorHotkeys = false
    private var isCapturingShortcut = false
    private var isAwaitingMicrophonePermission = false
    private var pendingMicrophonePermissionTriggerMode: RecordingTriggerMode?
    private var pendingMicrophonePermissionSelectionSnapshot: AppSelectionSnapshot?
    private var pendingMicrophonePermissionManualCommandRequested: Bool?
    private let postTranscriptionUpdateReminderDuration: TimeInterval = 7

    init() {
        UserDefaults.standard.removeObject(forKey: "force_http2_transcription")
        let hasCompletedSetup = UserDefaults.standard.bool(forKey: "hasCompletedSetup")
        let apiKey = Self.loadStoredAPIKey(account: apiKeyStorageKey)
        let apiBaseURL = Self.loadStoredAPIBaseURL(account: "api_base_url")
        let transcriptionModel = UserDefaults.standard.string(forKey: transcriptionModelStorageKey) ?? Self.defaultTranscriptionModel
        let transcriptionAPIURL = Self.loadOptionalStoredAPIValue(account: transcriptionAPIURLStorageKey)
        let transcriptionAPIKey = Self.loadStoredAPIKey(account: transcriptionAPIKeyStorageKey)
        let postProcessingModel = UserDefaults.standard.string(forKey: postProcessingModelStorageKey) ?? Self.defaultPostProcessingModel
        let postProcessingFallbackModel = Self.loadStoredPostProcessingFallbackModel(
            key: postProcessingFallbackModelStorageKey
        )
        let contextModel = Self.loadStoredContextModel(key: contextModelStorageKey)
        let shortcuts = Self.loadShortcutConfiguration(
            holdKey: holdShortcutStorageKey,
            toggleKey: toggleShortcutStorageKey,
            copyAgainKey: copyAgainShortcutStorageKey
        )
        let savedHoldCustomShortcut = Self.loadSavedCustomShortcut(
            forKey: savedHoldCustomShortcutStorageKey,
            fallback: shortcuts.hold.isCustom ? shortcuts.hold : nil
        )
        let savedToggleCustomShortcut = Self.loadSavedCustomShortcut(
            forKey: savedToggleCustomShortcutStorageKey,
            fallback: shortcuts.toggle.isCustom ? shortcuts.toggle : nil
        )
        let savedCopyAgainCustomShortcut = Self.loadSavedCustomShortcut(
            forKey: savedCopyAgainCustomShortcutStorageKey,
            fallback: shortcuts.copyAgain.isCustom ? shortcuts.copyAgain : nil
        )
        let customVocabulary = UserDefaults.standard.string(forKey: customVocabularyStorageKey) ?? ""
        let transcriptionLanguage = Self.normalizeTranscriptionLanguage(
            UserDefaults.standard.string(forKey: transcriptionLanguageStorageKey) ?? ""
        )
        let customSystemPrompt = UserDefaults.standard.string(forKey: customSystemPromptStorageKey) ?? ""
        let customContextPrompt = UserDefaults.standard.string(forKey: customContextPromptStorageKey) ?? ""
        let instructionExecutionGuardEnabled = UserDefaults.standard.object(
            forKey: instructionExecutionGuardEnabledStorageKey
        ) == nil
            ? true
            : UserDefaults.standard.bool(forKey: instructionExecutionGuardEnabledStorageKey)
        let customSystemPromptLastModified = UserDefaults.standard.string(forKey: customSystemPromptLastModifiedStorageKey) ?? ""
        let customContextPromptLastModified = UserDefaults.standard.string(forKey: customContextPromptLastModifiedStorageKey) ?? ""
        let outputLanguage = UserDefaults.standard.string(forKey: outputLanguageStorageKey) ?? ""
        let storedContextScreenshotMaxDimension = UserDefaults.standard.object(forKey: contextScreenshotMaxDimensionStorageKey) != nil
            ? UserDefaults.standard.integer(forKey: contextScreenshotMaxDimensionStorageKey)
            : Self.defaultContextScreenshotMaxDimension
        let contextScreenshotMaxDimension = Self.normalizedContextScreenshotMaxDimension(storedContextScreenshotMaxDimension)
        // Screenshots are off until asked for. That is what keeps a first
        // launch down to the microphone and Accessibility — the two the app
        // cannot work without — and leaves Screen Recording to be requested
        // by the switch that needs it, if it ever is.
        //
        // Cleanup and context keep their old default deliberately. Changing a
        // default silently changes the app for everyone who never touched that
        // switch, and neither of those two costs a permission.
        let contextScreenshotEnabled = UserDefaults.standard.object(forKey: contextScreenshotEnabledStorageKey) == nil
            ? false
            : UserDefaults.standard.bool(forKey: contextScreenshotEnabledStorageKey)
        let postProcessingEnabled = UserDefaults.standard.object(forKey: postProcessingEnabledStorageKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: postProcessingEnabledStorageKey)
        let contextInferenceEnabled = UserDefaults.standard.object(forKey: contextInferenceEnabledStorageKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: contextInferenceEnabledStorageKey)
        let transcriptionRequestFormat = TranscriptionRequestFormat.normalized(
            UserDefaults.standard.string(forKey: transcriptionRequestFormatStorageKey)
        )
        let transcriptionEngine = TranscriptionEngine.normalized(
            UserDefaults.standard.string(forKey: transcriptionEngineStorageKey)
        )
        let postProcessingEngine = PostProcessingEngine.normalized(
            UserDefaults.standard.string(forKey: postProcessingEngineStorageKey)
        )
        // Read without a closure: capturing an instance key inside one during
        // init counts as using self before every property is set.
        let learnedCorrectionsData = UserDefaults.standard.data(forKey: learnedCorrectionsStorageKey)
        let learnedCorrections = learnedCorrectionsData
            .flatMap { try? JSONDecoder().decode([WordCorrection].self, from: $0) } ?? []
        let learnedCorrectionsEnabled = UserDefaults.standard.object(
            forKey: learnedCorrectionsEnabledStorageKey
        ) == nil
            ? true
            : UserDefaults.standard.bool(forKey: learnedCorrectionsEnabledStorageKey)
        let correctionAdjudicationEnabled = UserDefaults.standard.bool(
            forKey: correctionAdjudicationEnabledStorageKey
        )
        let shortcutStartDelay = max(0, UserDefaults.standard.double(forKey: shortcutStartDelayStorageKey))
        let isCommandModeEnabled = UserDefaults.standard.object(forKey: commandModeEnabledStorageKey) == nil
            ? false
            : UserDefaults.standard.bool(forKey: commandModeEnabledStorageKey)
        let commandModeStyle = CommandModeStyle(
            rawValue: UserDefaults.standard.string(forKey: commandModeStyleStorageKey) ?? ""
        ) ?? .automatic
        let commandModeManualModifier = CommandModeManualModifier(
            rawValue: UserDefaults.standard.string(forKey: commandModeManualModifierStorageKey) ?? ""
        ) ?? .option
        let preserveClipboard = UserDefaults.standard.object(forKey: preserveClipboardStorageKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: preserveClipboardStorageKey)
        let preserveExactWording = UserDefaults.standard.bool(forKey: preserveExactWordingStorageKey)
        let keepDictationInClipboardHistory = UserDefaults.standard.bool(forKey: keepDictationInClipboardHistoryStorageKey)
        let realtimeStreamingEnabled = UserDefaults.standard.bool(forKey: realtimeStreamingEnabledStorageKey)
        let realtimeStreamingModel = UserDefaults.standard.string(forKey: realtimeStreamingModelStorageKey) ?? ""
        let dictationAudioInterruptionEnabled = UserDefaults.standard.bool(
            forKey: dictationAudioInterruptionEnabledStorageKey
        )
        let isPressEnterVoiceCommandEnabled = UserDefaults.standard.object(forKey: pressEnterVoiceCommandStorageKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: pressEnterVoiceCommandStorageKey)
        let soundVolume: Float = UserDefaults.standard.object(forKey: soundVolumeStorageKey) != nil
            ? UserDefaults.standard.float(forKey: soundVolumeStorageKey) : 1.0
        let alertSoundsEnabled = UserDefaults.standard.object(forKey: alertSoundsEnabledStorageKey) != nil
            ? UserDefaults.standard.bool(forKey: alertSoundsEnabledStorageKey)
            : soundVolume > 0
        
        let initialMacros: [VoiceMacro]
        if let data = UserDefaults.standard.data(forKey: "voice_macros"),
           let decoded = try? JSONDecoder().decode([VoiceMacro].self, from: data) {
            initialMacros = decoded
        } else {
            initialMacros = []
        }

        let initialAccessibility = AXIsProcessTrusted()
        // Not asked unless the setting that needs it is on. Merely preflighting
        // puts the app in the Screen Recording list, which reads as the app
        // wanting to record the screen — before it has any reason to.
        let initialScreenCapturePermission = contextScreenshotEnabled
            ? CGPreflightScreenCaptureAccess()
            : false
        var removedAudioFileNames: [String] = []
        do {
            removedAudioFileNames = try pipelineHistoryStore.trim(to: maxPipelineHistoryCount)
        } catch {
            print("Failed to trim pipeline history during init: \(error)")
        }
        for audioFileName in removedAudioFileNames {
            Self.deleteAudioFile(audioFileName)
        }
        let savedHistory = pipelineHistoryStore.loadAllHistory()

        let selectedMicrophoneID = UserDefaults.standard.string(forKey: selectedMicrophoneStorageKey) ?? "default"

        self.contextService = Self.makeAppContextService(
            apiKey: apiKey,
            baseURL: apiBaseURL,
            customContextPrompt: customContextPrompt,
            contextModel: contextModel,
            contextScreenshotMaxDimension: contextScreenshotMaxDimension,
            contextScreenshotEnabled: contextScreenshotEnabled,
            contextInferenceEnabled: contextInferenceEnabled
        )
        self.hasCompletedSetup = hasCompletedSetup
        self.apiKey = apiKey
        self.apiBaseURL = apiBaseURL
        self.transcriptionAPIURL = transcriptionAPIURL
        self.transcriptionAPIKey = transcriptionAPIKey
        self.transcriptionModel = transcriptionModel
        self.postProcessingModel = postProcessingModel
        self.postProcessingFallbackModel = postProcessingFallbackModel
        self.contextModel = contextModel
        self.holdShortcut = shortcuts.hold
        self.toggleShortcut = shortcuts.toggle
        self.copyAgainShortcut = shortcuts.copyAgain
        self.savedHoldCustomShortcut = savedHoldCustomShortcut.binding
        self.savedToggleCustomShortcut = savedToggleCustomShortcut.binding
        self.savedCopyAgainCustomShortcut = savedCopyAgainCustomShortcut.binding
        self.isCommandModeEnabled = isCommandModeEnabled
        self.commandModeStyle = commandModeStyle
        self.commandModeManualModifier = commandModeManualModifier
        self.customVocabulary = customVocabulary
        self.transcriptionLanguage = transcriptionLanguage
        self.customSystemPrompt = customSystemPrompt
        self.customContextPrompt = customContextPrompt
        self.instructionExecutionGuardEnabled = instructionExecutionGuardEnabled
        self.contextScreenshotMaxDimension = contextScreenshotMaxDimension
        self.notetakerEngine = TranscriptionEngine.normalized(
            UserDefaults.standard.string(forKey: notetakerEngineStorageKey) ?? "local"
        )
        self.contextScreenshotEnabled = contextScreenshotEnabled
        self.postProcessingEnabled = postProcessingEnabled
        self.contextInferenceEnabled = contextInferenceEnabled
        self.transcriptionRequestFormat = transcriptionRequestFormat
        self.transcriptionEngine = transcriptionEngine
        self.postProcessingEngine = postProcessingEngine
        self.learnedCorrections = learnedCorrections
        self.learnedCorrectionsEnabled = learnedCorrectionsEnabled
        self.correctionAdjudicationEnabled = correctionAdjudicationEnabled
        self.customSystemPromptLastModified = customSystemPromptLastModified
        self.customContextPromptLastModified = customContextPromptLastModified
        self.outputLanguage = outputLanguage
        self.shortcutStartDelay = shortcutStartDelay
        self.preserveClipboard = preserveClipboard
        self.preserveExactWording = preserveExactWording
        self.keepDictationInClipboardHistory = keepDictationInClipboardHistory
        self.realtimeStreamingEnabled = realtimeStreamingEnabled
        self.realtimeStreamingModel = realtimeStreamingModel
        self.dictationAudioInterruptionEnabled = dictationAudioInterruptionEnabled
        self.isPressEnterVoiceCommandEnabled = isPressEnterVoiceCommandEnabled
        self.alertSoundsEnabled = alertSoundsEnabled
        self.soundVolume = soundVolume
        self.voiceMacros = initialMacros
        self.pipelineHistory = savedHistory
        self.hasAccessibility = initialAccessibility
        self.hasScreenRecordingPermission = initialScreenCapturePermission
        self.launchAtLogin = SMAppService.mainApp.status == .enabled
        self.selectedMicrophoneID = selectedMicrophoneID
        self.precomputeMacros()

        refreshAvailableMicrophones()
        installAudioDeviceObservers()
        installCorrectionWatcher()
        installSettingsBridge()

        if shortcuts.didUpdateHoldStoredValue {
            persistShortcut(shortcuts.hold, key: holdShortcutStorageKey)
        }
        if shortcuts.didUpdateToggleStoredValue {
            persistShortcut(shortcuts.toggle, key: toggleShortcutStorageKey)
        }
        if shortcuts.didUpdateCopyAgainStoredValue {
            persistShortcut(shortcuts.copyAgain, key: copyAgainShortcutStorageKey)
        }
        if savedHoldCustomShortcut.didUpdateStoredValue {
            persistOptionalShortcut(savedHoldCustomShortcut.binding, key: savedHoldCustomShortcutStorageKey)
        }
        if savedToggleCustomShortcut.didUpdateStoredValue {
            persistOptionalShortcut(savedToggleCustomShortcut.binding, key: savedToggleCustomShortcutStorageKey)
        }
        if savedCopyAgainCustomShortcut.didUpdateStoredValue {
            persistOptionalShortcut(savedCopyAgainCustomShortcut.binding, key: savedCopyAgainCustomShortcutStorageKey)
        }

        overlayManager.onStopButtonPressed = { [weak self] in
            DispatchQueue.main.async {
                self?.handleOverlayStopButtonPressed()
            }
        }
        overlayManager.onUpdateOverlayPressed = { [weak self] in
            DispatchQueue.main.async {
                self?.handleUpdateOverlayPressed()
            }
        }

        // Clear any stale recording flag left over from an unclean exit.
        AppState.writeRecordingStateFlag(false)
    }

    deinit {
        removeAudioDeviceObservers()
        AppState.writeRecordingStateFlag(false)
    }

    private func removeAudioDeviceObservers() {
        let notificationCenter = NotificationCenter.default
        for observer in audioDeviceObservers {
            notificationCenter.removeObserver(observer)
        }
        audioDeviceObservers.removeAll()
    }

    private static func loadStoredAPIKey(account: String) -> String {
        if let storedKey = AppSettingsStorage.load(account: account), !storedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return storedKey
        }
        return ""
    }

    private func persistAPIKey(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            AppSettingsStorage.delete(account: apiKeyStorageKey)
        } else {
            AppSettingsStorage.save(trimmed, account: apiKeyStorageKey)
        }
    }

    static let defaultAPIBaseURL = "https://api.groq.com/openai/v1"

    private struct StoredShortcutConfiguration {
        let hold: ShortcutBinding
        let toggle: ShortcutBinding
        let copyAgain: ShortcutBinding
        let didUpdateHoldStoredValue: Bool
        let didUpdateToggleStoredValue: Bool
        let didUpdateCopyAgainStoredValue: Bool
    }

    private struct StoredOptionalShortcut {
        let binding: ShortcutBinding?
        let didUpdateStoredValue: Bool
    }

    private struct StoredShortcutLoadResult {
        let binding: ShortcutBinding?
        let hadStoredValue: Bool
        let didNormalize: Bool
    }

    private static func loadStoredAPIBaseURL(account: String) -> String {
        if let stored = AppSettingsStorage.load(account: account), !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return stored
        }
        return defaultAPIBaseURL
    }

    private static func loadStoredContextModel(key: String) -> String {
        guard let stored = UserDefaults.standard.string(forKey: key) else {
            return defaultContextModel
        }

        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == deprecatedDefaultContextModel {
            UserDefaults.standard.set(defaultContextModel, forKey: key)
            return defaultContextModel
        }

        return trimmed.isEmpty ? defaultContextModel : trimmed
    }

    private static func loadStoredPostProcessingFallbackModel(key: String) -> String {
        guard let stored = UserDefaults.standard.string(forKey: key) else {
            return defaultPostProcessingFallbackModel
        }

        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == deprecatedDefaultPostProcessingFallbackModel {
            UserDefaults.standard.set(defaultPostProcessingFallbackModel, forKey: key)
            return defaultPostProcessingFallbackModel
        }

        return trimmed.isEmpty ? defaultPostProcessingFallbackModel : trimmed
    }

    private static func loadShortcutConfiguration(
        holdKey: String,
        toggleKey: String,
        copyAgainKey: String
    ) -> StoredShortcutConfiguration {
        let legacyPreset = ShortcutPreset(
            rawValue: UserDefaults.standard.string(forKey: "hotkey_option") ?? ShortcutPreset.fnKey.rawValue
        ) ?? .fnKey
        let hold = legacyPreset.binding
        let toggle = hold.withAddedModifiers(.command)
        let storedHold = loadShortcut(forKey: holdKey)
        let storedToggle = loadShortcut(forKey: toggleKey)
        let storedCopyAgain = loadShortcut(forKey: copyAgainKey)
        return StoredShortcutConfiguration(
            hold: storedHold.binding ?? hold,
            toggle: storedToggle.binding ?? toggle,
            copyAgain: storedCopyAgain.binding ?? .disabled,
            didUpdateHoldStoredValue: storedHold.binding == nil || storedHold.didNormalize,
            didUpdateToggleStoredValue: storedToggle.binding == nil || storedToggle.didNormalize,
            didUpdateCopyAgainStoredValue: storedCopyAgain.didNormalize
        )
    }

    private static func loadShortcut(forKey key: String) -> StoredShortcutLoadResult {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return StoredShortcutLoadResult(binding: nil, hadStoredValue: false, didNormalize: false)
        }
        guard let decoded = try? JSONDecoder().decode(ShortcutBinding.self, from: data) else {
            return StoredShortcutLoadResult(binding: nil, hadStoredValue: true, didNormalize: false)
        }
        let normalized = decoded.normalizedForStorageMigration()
        return StoredShortcutLoadResult(
            binding: normalized,
            hadStoredValue: true,
            didNormalize: normalized != decoded
        )
    }

    private static func loadSavedCustomShortcut(
        forKey key: String,
        fallback: ShortcutBinding?
    ) -> StoredOptionalShortcut {
        let stored = loadShortcut(forKey: key)
        if let binding = stored.binding {
            return StoredOptionalShortcut(binding: binding, didUpdateStoredValue: stored.didNormalize)
        }

        return StoredOptionalShortcut(
            binding: fallback,
            didUpdateStoredValue: stored.hadStoredValue || fallback != nil
        )
    }

    static func normalizedContextScreenshotMaxDimension(_ value: Int) -> Int {
        contextScreenshotDimensionOptions.contains(value)
            ? value
            : defaultContextScreenshotMaxDimension
    }

    static func makeAppContextService(
        apiKey: String,
        baseURL: String,
        customContextPrompt: String,
        contextModel: String,
        contextScreenshotMaxDimension: Int,
        contextScreenshotEnabled: Bool,
        contextInferenceEnabled: Bool
    ) -> AppContextService {
        AppContextService(
            apiKey: apiKey,
            baseURL: baseURL,
            customContextPrompt: customContextPrompt,
            contextModel: contextModel,
            screenshotMaxDimension: CGFloat(normalizedContextScreenshotMaxDimension(contextScreenshotMaxDimension)),
            // A screenshot exists only to feed the context request, so turning
            // inference off turns the capture off with it.
            screenshotCaptureEnabled: contextScreenshotEnabled && contextInferenceEnabled,
            inferenceEnabled: contextInferenceEnabled
        )
    }

    func makeAppContextService() -> AppContextService {
        Self.makeAppContextService(
            apiKey: apiKey,
            baseURL: apiBaseURL,
            customContextPrompt: customContextPrompt,
            contextModel: contextModel,
            contextScreenshotMaxDimension: contextScreenshotMaxDimension,
            contextScreenshotEnabled: contextScreenshotEnabled,
            contextInferenceEnabled: contextInferenceEnabled
        )
    }

    /// The preset matching the current toggles, or nil when they form a
    /// combination no preset covers. Derived rather than stored so the mode and
    /// the individual toggles can never disagree.
    var pipelineMode: PipelineMode? {
        PipelineMode.matching(
            postProcessingEnabled: postProcessingEnabled,
            contextInferenceEnabled: contextInferenceEnabled,
            screenshotEnabled: contextScreenshotEnabled
        )
    }

    func applyPipelineMode(_ mode: PipelineMode) {
        postProcessingEnabled = mode.postProcessingEnabled
        contextInferenceEnabled = mode.contextInferenceEnabled
        contextScreenshotEnabled = mode.screenshotEnabled
    }

    private func rebuildContextService() {
        contextService = makeAppContextService()
    }

    private func persistAPIBaseURL(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == Self.defaultAPIBaseURL {
            AppSettingsStorage.delete(account: apiBaseURLStorageKey)
        } else {
            AppSettingsStorage.save(trimmed, account: apiBaseURLStorageKey)
        }
    }

    private func persistOptionalAPIValue(_ value: String, account: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            AppSettingsStorage.delete(account: account)
        } else {
            AppSettingsStorage.save(trimmed, account: account)
        }
    }

    private static func loadOptionalStoredAPIValue(account: String) -> String {
        let stored = AppSettingsStorage.load(account: account) ?? ""
        return stored.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeTranscriptionLanguage(_ language: String) -> String {
        let normalized = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard transcriptionLanguageOptions.contains(where: { $0.code == normalized }) else {
            return ""
        }
        return normalized
    }

    var resolvedTranscriptionBaseURL: String {
        let trimmed = transcriptionAPIURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? apiBaseURL : trimmed
    }

    private var resolvedTranscriptionAPIKey: String {
        let trimmed = transcriptionAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? apiKey : trimmed
    }

    func makeTranscriptionService() throws -> TranscriptionService {
        try TranscriptionService(
            apiKey: resolvedTranscriptionAPIKey,
            baseURL: resolvedTranscriptionBaseURL,
            transcriptionModel: transcriptionModel,
            language: resolvedTranscriptionLanguage,
            requestFormat: transcriptionRequestFormat
        )
    }

    private var resolvedTranscriptionLanguage: String? {
        let normalized = Self.normalizeTranscriptionLanguage(transcriptionLanguage)
        return normalized.isEmpty ? nil : normalized
    }

    private func persistShortcut(_ binding: ShortcutBinding, key: String) {
        let normalizedBinding = binding.normalizedForStorageMigration()
        guard let data = try? JSONEncoder().encode(normalizedBinding) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func persistOptionalShortcut(_ binding: ShortcutBinding?, key: String) {
        guard let binding else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        persistShortcut(binding, key: key)
    }

    struct SavedAudioFile {
        let fileName: String
        let fileURL: URL
    }

    /// Where ZFlow keeps its own files, including the UI bridge handshake.
    static func applicationSupportDirectory() -> URL {
        AppPaths.applicationSupportDirectory()
    }

    static func audioStorageDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appName = AppName.displayName
        let audioDir = appSupport.appendingPathComponent("\(appName)/audio", isDirectory: true)
        if !FileManager.default.fileExists(atPath: audioDir.path) {
            try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        }
        return audioDir
    }

    /// URL of the flag file written while ZFlow is actively recording.
    ///
    /// External tools (voice assistants, TTS barge-in pipelines, conversation
    /// apps) can poll this file to know when the user is dictating. The file
    /// exists while `isRecording` is true and is removed when it flips false.
    /// Contents are the UNIX timestamp (seconds, float) of when recording
    /// started — useful for stale-flag detection after an unclean exit.
    ///
    /// Path: `~/Library/Application Support/ZFlow/is-recording`
    /// (or `ZFlow Dev/is-recording` when running the dev bundle).
    static func recordingStateFlagURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "ZFlow"
        return appSupport.appendingPathComponent("\(appName)/is-recording")
    }

    /// Serial queue that owns every flag-file I/O so the recording
    /// start/stop hot path never blocks on disk.
    private static let recordingStateFlagQueue = DispatchQueue(
        label: "com.zippy.zflow.recording-state-flag"
    )

    /// Write or clear the `is-recording` flag file. Called from the
    /// `isRecording` didSet. Dispatches to a background queue so disk
    /// I/O never adds latency to recording start/stop. Failures are
    /// swallowed — this is advisory IPC and must never interrupt the
    /// recording pipeline.
    static func writeRecordingStateFlag(_ recording: Bool) {
        let timestamp = recording ? String(Date().timeIntervalSince1970) : nil
        recordingStateFlagQueue.async {
            let url = recordingStateFlagURL()
            if let timestamp {
                let dir = url.deletingLastPathComponent()
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? timestamp.write(to: url, atomically: true, encoding: .utf8)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    static func saveAudioFile(from tempURL: URL) -> SavedAudioFile? {
        let fileName = UUID().uuidString + ".wav"
        let destURL = audioStorageDirectory().appendingPathComponent(fileName)
        do {
            try FileManager.default.copyItem(at: tempURL, to: destURL)
            return SavedAudioFile(fileName: fileName, fileURL: destURL)
        } catch {
            os_log(
                .error,
                log: recordingLog,
                "failed to persist audio file %{public}@ from %{public}@ to %{public}@ : %{public}@",
                fileName,
                tempURL.path,
                destURL.path,
                error.localizedDescription
            )
            return nil
        }
    }

    private static func deleteAudioFile(_ fileName: String) {
        let fileURL = audioStorageDirectory().appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: fileURL)
    }

    func clearPipelineHistory() {
        do {
            let removedAudioFileNames = try pipelineHistoryStore.clearAll()
            for audioFileName in removedAudioFileNames {
                Self.deleteAudioFile(audioFileName)
            }
            pipelineHistory = []
        } catch {
            errorMessage = "Unable to clear run history: \(error.localizedDescription)"
        }
    }

    func deleteHistoryEntry(id: UUID) {
        guard let index = pipelineHistory.firstIndex(where: { $0.id == id }) else { return }
        do {
            if let audioFileName = try pipelineHistoryStore.delete(id: id) {
                Self.deleteAudioFile(audioFileName)
            }
            pipelineHistory.remove(at: index)
        } catch {
            errorMessage = "Unable to delete run history entry: \(error.localizedDescription)"
        }
    }

    /// True when a failed run's audio is still on disk, which is what makes a
    /// retry possible without asking the user to speak again.
    static func audioFileExists(named audioFileName: String?) -> Bool {
        guard let audioFileName, !audioFileName.isEmpty else { return false }
        let url = audioStorageDirectory().appendingPathComponent(audioFileName)
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// - Parameter presentsLiveFeedback: true when the retry stands in for a
    ///   dictation that just failed, rather than a replay from the Run Log. The
    ///   overlay then shows progress, the text is pasted at the cursor the way
    ///   the original dictation would have, and a second failure offers another
    ///   retry. From the Run Log the result goes to the clipboard only, because
    ///   there is no cursor the user was dictating into.
    func retryTranscription(item: PipelineHistoryItem, presentsLiveFeedback: Bool = false) {
        guard let audioFileName = item.audioFileName else { return }
        guard !retryingItemIDs.contains(item.id) else { return }

        retryingItemIDs.insert(item.id)

        let audioURL = Self.audioStorageDirectory().appendingPathComponent(audioFileName)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            retryingItemIDs.remove(item.id)
            errorMessage = "Audio file not found for retry."
            return
        }

        if presentsLiveFeedback {
            errorMessage = nil
            statusText = "Transcribing..."
            overlayManager.showTranscribing()
        }

        let restoredContext = AppContext(
            appName: nil,
            bundleIdentifier: nil,
            windowTitle: nil,
            selectedText: nil,
            currentActivity: item.contextSummary,
            contextSystemPrompt: item.contextSystemPrompt,
            contextPrompt: item.contextPrompt,
            screenshotDataURL: item.contextScreenshotDataURL,
            screenshotMimeType: item.contextScreenshotDataURL != nil ? "image/jpeg" : nil,
            screenshotError: nil
        )

        let postProcessingService = PostProcessingService(
            apiKey: apiKey,
            baseURL: apiBaseURL,
            preferredModel: postProcessingModel,
            preferredFallbackModel: postProcessingFallbackModel,
            instructionExecutionGuardEnabled: instructionExecutionGuardEnabled
        )
        let capturedCustomVocabulary = vocabularyIncludingLearnedSpellings
        let capturedCustomSystemPrompt = customSystemPrompt
        // The engine chosen now, not the provider by default: a retry is the
        // same request made again. Going to the provider regardless uploaded
        // every retried on-device dictation — the one thing choosing
        // on-device promises will not happen.
        let route = transcriptionEngine.retryRoute(localSupported: Self.isLocalTranscriptionSupported)
        let languageCode = resolvedTranscriptionLanguage

        Task {
            do {
                let rawTranscript: String
                switch route {
                case .onDevice:
                    guard #available(macOS 26.0, *) else { throw FileTranscriptionError.localUnavailable }
                    rawTranscript = try await FileTranscriptionService.transcribeLocally(
                        url: audioURL,
                        languageCode: languageCode,
                        onProgress: { _ in }
                    )
                case .provider:
                    rawTranscript = try await makeTranscriptionService().transcribe(fileURL: audioURL)
                case .unavailable:
                    throw FileTranscriptionError.localUnavailable
                }
                let parsedTranscript = Self.parseTranscriptCommands(
                    from: rawTranscript,
                    pressEnterCommandEnabled: self.isPressEnterVoiceCommandEnabled
                )

                let finalTranscript: String
                let processingStatus: String
                let postProcessingPrompt: String
                let restoredIntent = SessionIntent.fromPersisted(
                    intent: item.intent,
                    selectedText: item.selectedText
                )
                let result = await self.processTranscript(
                    parsedTranscript.transcript,
                    intent: restoredIntent,
                    context: restoredContext,
                    postProcessingService: postProcessingService,
                    customVocabulary: capturedCustomVocabulary,
                    customSystemPrompt: capturedCustomSystemPrompt,
                    outputLanguage: self.outputLanguage,
                    preserveExactWording: self.preserveExactWording,
                    postProcessingEnabled: self.postProcessingEnabled
                )
                finalTranscript = result.finalTranscript
                processingStatus = Self.statusMessage(
                    for: result.outcome,
                    parsedTranscript: parsedTranscript,
                    isRetry: true
                )
                postProcessingPrompt = result.prompt

                await MainActor.run {
                    let updatedItem = PipelineHistoryItem(
                        intent: item.intent,
                        selectedText: item.selectedText,
                        capturedSelection: item.capturedSelection,
                        id: item.id,
                        timestamp: item.timestamp,
                        rawTranscript: parsedTranscript.transcript,
                        postProcessedTranscript: finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines),
                        postProcessingPrompt: postProcessingPrompt,
                        systemPrompt: item.systemPrompt,
                        contextSummary: item.contextSummary,
                        contextSystemPrompt: item.contextSystemPrompt,
                        contextPrompt: item.contextPrompt,
                        contextScreenshotDataURL: item.contextScreenshotDataURL,
                        contextScreenshotStatus: item.contextScreenshotStatus,
                        postProcessingStatus: processingStatus,
                        debugStatus: "Retried",
                        customVocabulary: item.customVocabulary,
                        audioFileName: item.audioFileName,
                        contextAppName: item.contextAppName,
                        contextBundleIdentifier: item.contextBundleIdentifier,
                        contextWindowTitle: item.contextWindowTitle
                    )
                    do {
                        try pipelineHistoryStore.update(updatedItem)
                        pipelineHistory = pipelineHistoryStore.loadAllHistory()
                        let trimmedRetryTranscript = finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmedRetryTranscript.isEmpty {
                            lastTranscript = trimmedRetryTranscript
                            if presentsLiveFeedback {
                                let pendingRestore = writeTranscriptToPasteboard(trimmedRetryTranscript)
                                pasteAtCursorWhenShortcutReleased {
                                    self.restoreClipboardIfNeeded(pendingRestore)
                                }
                            } else {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(trimmedRetryTranscript, forType: .string)
                            }
                        }
                    } catch {
                        errorMessage = "Failed to save retry result: \(error.localizedDescription)"
                    }
                    if presentsLiveFeedback {
                        statusText = finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "Nothing to transcribe"
                            : "Pasted"
                        overlayManager.dismiss()
                        scheduleReadyStatusReset(after: 3, matching: ["Pasted", "Nothing to transcribe"])
                    }
                    retryingItemIDs.remove(item.id)
                }
            } catch {
                await MainActor.run {
                    let updatedItem = PipelineHistoryItem(
                        intent: item.intent,
                        selectedText: item.selectedText,
                        capturedSelection: item.capturedSelection,
                        id: item.id,
                        timestamp: item.timestamp,
                        rawTranscript: item.rawTranscript,
                        postProcessedTranscript: item.postProcessedTranscript,
                        postProcessingPrompt: item.postProcessingPrompt,
                        systemPrompt: item.systemPrompt,
                        contextSummary: item.contextSummary,
                        contextSystemPrompt: item.contextSystemPrompt,
                        contextPrompt: item.contextPrompt,
                        contextScreenshotDataURL: item.contextScreenshotDataURL,
                        contextScreenshotStatus: item.contextScreenshotStatus,
                        postProcessingStatus: "Error: \(error.localizedDescription)",
                        debugStatus: "Retry failed",
                        customVocabulary: item.customVocabulary,
                        audioFileName: item.audioFileName,
                        contextAppName: item.contextAppName,
                        contextBundleIdentifier: item.contextBundleIdentifier,
                        contextWindowTitle: item.contextWindowTitle
                    )
                    do {
                        try pipelineHistoryStore.update(updatedItem)
                        pipelineHistory = pipelineHistoryStore.loadAllHistory()
                    } catch {}
                    retryingItemIDs.remove(item.id)
                    if presentsLiveFeedback {
                        // Offer the retry again: a transient provider failure
                        // is exactly the case where a second attempt works.
                        let message = formattedTranscriptionError(error)
                        errorMessage = message
                        statusText = "Error"
                        overlayManager.showError(message, retry: { [weak self] in
                            self?.retryTranscription(item: updatedItem, presentsLiveFeedback: true)
                        })
                    }
                }
            }
        }
    }

    /// Watches the permissions until nothing is left to recover, and brings
    /// the shortcut back the moment macOS allows it.
    ///
    /// See `HotkeyRecoveryCore`: the shortcut fails to install on a launch
    /// without Accessibility, and nothing used to try again once it was
    /// granted.
    func startAccessibilityPolling() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = nil
        guard !checkPermissionsAndRecover() else { return }

        // In the common modes, not the default one. A default-mode timer
        // does not fire while any modal alert is up — and an alert that sat
        // hidden behind other windows once stalled this watch for as long as
        // it stayed open.
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.checkPermissionsAndRecover() else { return }
                self.accessibilityTimer?.invalidate()
                self.accessibilityTimer = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        accessibilityTimer = timer
    }

    /// Reads the permissions, reinstalls the shortcut if it is missing and
    /// now allowed, and says whether the watch can stop.
    @discardableResult
    private func checkPermissionsAndRecover() -> Bool {
        hasAccessibility = AXIsProcessTrusted()
        hasScreenRecordingPermission = hasScreenCapturePermission()
        hasMicrophonePermission = hasMicrophoneAccess()

        if HotkeyRecoveryCore.shouldInstallTap(
            monitoringWanted: hotkeyMonitoringWanted,
            tapInstalled: hotkeyManager.isRunning,
            accessibilityTrusted: hasAccessibility
        ) {
            os_log(.default, log: recordingLog, "Accessibility is available; installing the global shortcut")
            restartHotkeyMonitoring()
        }

        return HotkeyRecoveryCore.canStopWatching(
            allNeededPermissionsGranted: allNeededPermissionsGranted,
            monitoringWanted: hotkeyMonitoringWanted,
            tapInstalled: hotkeyManager.isRunning
        )
    }

    /// Monitoring is paused on purpose while a shortcut is being recorded or
    /// the microphone prompt is up. Anything else that leaves it off is a
    /// failure to recover from.
    private var hotkeyMonitoringWanted: Bool {
        shouldMonitorHotkeys && !isCapturingShortcut && !isAwaitingMicrophonePermission
    }

    func stopAccessibilityPolling() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = nil
    }

    func openAccessibilitySettings() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            openPrivacySettingsPane("Privacy_Accessibility")
        }
    }

    func openMicrophoneSettings() {
        openPrivacySettingsPane("Privacy_Microphone")
    }

    func requestMicrophoneAccess(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            refreshAvailableMicrophones()
            DispatchQueue.main.async {
                completion(true)
            }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.refreshAvailableMicrophones()
                    }
                    completion(granted)
                }
            }
        case .denied, .restricted:
            openMicrophoneSettings()
            DispatchQueue.main.async {
                completion(false)
            }
        @unknown default:
            openMicrophoneSettings()
            DispatchQueue.main.async {
                completion(false)
            }
        }
    }

    /// Whether screen recording is a permission this app currently needs at
    /// all. Off, nothing reads it and nothing complains about it.
    var screenRecordingRequired: Bool { contextScreenshotEnabled }

    var allNeededPermissionsGranted: Bool {
        hasAccessibility
            && hasMicrophonePermission
            && (!screenRecordingRequired || hasScreenRecordingPermission)
    }

    func hasScreenCapturePermission() -> Bool {
        guard screenRecordingRequired else { return false }
        return CGPreflightScreenCaptureAccess()
    }

    /// Only `.authorized` counts. `.notDetermined` means the system prompt has
    /// never been shown, which is indistinguishable from denied until someone
    /// tries to record — so it is reported as missing and asked for up front.
    func hasMicrophoneAccess() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    private let screenCaptureAskedOnceKey = "screen_capture_asked_once"

    func requestScreenCapturePermission() {
        // The first ask is macOS's own dialog and nothing else. Opening System
        // Settings on top of it would be answering a question the user has not
        // been shown yet — the preflight below returns false either way, both
        // while the dialog is still open and when it has been refused.
        let askedBefore = UserDefaults.standard.bool(forKey: screenCaptureAskedOnceKey)
        UserDefaults.standard.set(true, forKey: screenCaptureAskedOnceKey)

        // ScreenCaptureKit triggers the "Screen & System Audio Recording"
        // permission dialog on macOS Sequoia+, correctly identifying the
        // running app (unlike the legacy CGWindowListCreateImage path).
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let granted = CGPreflightScreenCaptureAccess()
                self.hasScreenRecordingPermission = granted
                // Only send someone to System Settings once the dialog can no
                // longer be the explanation: macOS shows it once, and after
                // that a refusal can only be undone there.
                if !granted && askedBefore {
                    self.openScreenCaptureSettings()
                }
                self.startAccessibilityPolling()
            }
        }

        hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
    }

    func openScreenCaptureSettings() {
        openPrivacySettingsPane("Privacy_ScreenCapture")
    }

    private func openPrivacySettingsPane(_ pane: String) {
        let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
        if let url = settingsURL {
            NSWorkspace.shared.open(url)
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Revert the toggle on failure without re-triggering didSet
            let current = SMAppService.mainApp.status == .enabled
            if current != launchAtLogin {
                launchAtLogin = current
            }
        }
    }

    func refreshLaunchAtLoginStatus() {
        let current = SMAppService.mainApp.status == .enabled
        if current != launchAtLogin {
            launchAtLogin = current
        }
    }

    func refreshAvailableMicrophones() {
        guard !isRecording, !audioRecorder.isRecording else {
            needsMicrophoneRefreshAfterRecording = true
            return
        }

        needsMicrophoneRefreshAfterRecording = false
        availableMicrophones = AudioDevice.availableInputDevices()
    }

    private func refreshAvailableMicrophonesIfNeeded() {
        guard needsMicrophoneRefreshAfterRecording else { return }
        refreshAvailableMicrophones()
    }

    /// Begins watching once the paste has actually landed. The delay covers
    /// the keystroke and the target app's own redraw; reading too early finds
    /// the field as it was before.
    private func beginWatchingForCorrections(of transcript: String) {
        guard learnedCorrectionsEnabled else {
            os_log(.info, log: recordingLog, "not watching for corrections: learning is turned off in Settings")
            return
        }
        let delay = pasteAfterShortcutReleaseDelay + 0.45
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.correctionWatcher.beginWatching(pastedText: transcript)
        }
    }

    /// Exposes settings to the Electron front end while the app is running.
    ///
    /// Reads and writes go through the same published properties the SwiftUI
    /// settings use, so a change from either surface takes effect immediately
    /// and both stay in step.
    private func installSettingsBridge() {
        let bridge = SettingsBridgeServer.shared

        bridge.readHandler = { [weak self] key in
            guard let self else { return nil }
            return DispatchQueue.main.sync { self.bridgeValue(forKey: key) }
        }
        bridge.writeHandler = { [weak self] key, value in
            guard let self else { return false }
            return DispatchQueue.main.sync { self.applyBridgeValue(value, forKey: key) }
        }
        bridge.historyHandler = { [weak self] in
            guard let self else { return [] }
            return DispatchQueue.main.sync {
                self.pipelineHistory.prefix(50).map { item in
                    // The same detail the native Run Log shows, so the row can
                    // expand into the pipeline rather than just the result.
                    // Unwrapped first: inside a large [String: Any] literal Swift
                    // gives up on inferring these and coerces the Optional.
                    let app: String = item.contextAppName ?? ""
                    let windowTitle: String = item.contextWindowTitle ?? ""
                    let contextPrompt: String = item.contextPrompt ?? ""
                    let cleanupPrompt: String = item.postProcessingPrompt ?? ""
                    let selectedText: String = item.selectedText ?? ""
                    let systemPrompt: String = item.systemPrompt ?? ""
                    let entry: [String: Any] = [
                        "id": item.id.uuidString,
                        "timestamp": Self.bridgeDateFormatter.string(from: item.timestamp),
                        "transcript": item.postProcessedTranscript.isEmpty
                            ? item.rawTranscript
                            : item.postProcessedTranscript,
                        "rawTranscript": item.rawTranscript,
                        // Sent separately from `transcript`, which falls back
                        // to the raw one: the UI has to be able to say that
                        // cleanup did not run, and "they are equal" cannot
                        // distinguish that from "it changed nothing".
                        "cleanedTranscript": item.postProcessedTranscript,
                        "status": item.postProcessingStatus,
                        "debugStatus": item.debugStatus,
                        "app": app,
                        "windowTitle": windowTitle,
                        "contextSummary": item.contextSummary,
                        "contextPrompt": contextPrompt,
                        "postProcessingPrompt": cleanupPrompt,
                        "systemPrompt": systemPrompt,
                        "screenshotStatus": item.contextScreenshotStatus,
                        "selectedText": selectedText,
                        "hasAudio": item.audioFileName != nil
                    ]
                    return entry
                }
            }
        }
        bridge.quitHandler = {
            // Given a moment so the reply reaches the settings window before
            // the socket goes with the process.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                NSApplication.shared.terminate(nil)
            }
        }
        bridge.historyDeleteHandler = { [weak self] id in
            guard let self, let uuid = UUID(uuidString: id) else { return false }
            return DispatchQueue.main.sync {
                guard self.pipelineHistory.contains(where: { $0.id == uuid }) else { return false }
                self.deleteHistoryEntry(id: uuid)
                return true
            }
        }
        bridge.dictionaryMutationHandler = { [weak self] action, body in
            guard let self else { return false }
            return DispatchQueue.main.sync {
                switch action {
                case "add":
                    guard let heard = body["original"] as? String,
                          let corrected = body["corrected"] as? String else { return false }
                    self.addHeardForm(heard, correctedTo: corrected)
                case "removeVariant":
                    guard let id = body["id"] as? String else { return false }
                    self.forgetCorrection(id: id)
                case "rename":
                    guard let from = body["from"] as? String,
                          let to = body["to"] as? String else { return false }
                    self.renameCorrectedSpelling(from: from, to: to)
                case "removeGroup":
                    guard let corrected = body["corrected"] as? String else { return false }
                    self.forgetCorrectedSpelling(corrected)
                default:
                    return false
                }
                return true
            }
        }
        bridge.permissionsHandler = { [weak self] in
            guard let self else { return ["items": []] }
            return DispatchQueue.main.sync {
                // Read, never ask. Every call below reports what the system
                // has already been told; none of them raises a dialog, so
                // opening the settings page cannot start demanding things.
                let items = PermissionsCore.items(
                    microphoneGranted: self.hasMicrophoneAccess(),
                    accessibilityGranted: AXIsProcessTrusted(),
                    screenRecordingGranted: CGPreflightScreenCaptureAccess(),
                    screenRecordingNeeded: self.screenRecordingRequired
                )
                return [
                    "items": items.map {
                        [
                            "access": $0.access.rawValue,
                            "title": $0.title,
                            "purpose": $0.purpose,
                            "state": $0.state.rawValue,
                        ]
                    },
                    "allGranted": PermissionsCore.everythingNeededIsGranted(items),
                    "outstanding": PermissionsCore.outstandingCount(items),
                ]
            }
        }

        bridge.permissionRequestHandler = { [weak self] raw in
            guard let self, let access = PermissionsCore.Access(rawValue: raw) else { return false }
            DispatchQueue.main.async {
                switch access {
                case .microphone:
                    // Never granted means macOS has a dialog to show. Refused
                    // means it will not show one again, and this opens the
                    // pane instead — both handled here already.
                    self.requestMicrophoneAccess { _ in self.startAccessibilityPolling() }
                case .accessibility:
                    self.openAccessibilitySettings()
                    // So the rest of the app notices the moment it is given:
                    // the poll stops itself once nothing is outstanding.
                    self.startAccessibilityPolling()
                case .screenRecording:
                    self.requestScreenCapturePermission()
                }
            }
            return true
        }

        bridge.microphonesHandler = { [weak self] in
            guard let self else { return [] }
            return DispatchQueue.main.sync {
                [["id": "default", "name": "System default"]]
                    + self.availableMicrophones.map { ["id": $0.uid, "name": $0.name] }
            }
        }
        bridge.dictionaryHandler = { [weak self] in
            guard let self else { return [] }
            return DispatchQueue.main.sync {
                self.learnedCorrections.map { correction in
                    [
                        "id": correction.id,
                        "original": correction.original,
                        "corrected": correction.corrected,
                        "occurrences": correction.occurrences
                    ]
                }
            }
        }

        bridge.defaultsHandler = {
            // Static app text, not user data: what an empty prompt field
            // falls back to, so the front end can show it instead of a blank
            // box that looks broken.
            [
                "custom_system_prompt": PostProcessingService.defaultSystemPrompt,
                "custom_context_prompt": AppContextService.defaultContextPrompt
            ]
        }
        bridge.insightsHandler = {
            let stats = UsageStatisticsStore.shared.load()
            let byApp = stats.wordsByApp
                .sorted { $0.value > $1.value }
                .prefix(8)
                .map { ["name": $0.key, "words": $0.value] as [String: Any] }
            let minutesSaved = SavingsCore.minutesNotSpentTyping(
                words: stats.totalWords,
                speakingSeconds: stats.totalSpeakingSeconds
            )
            let moneySaved = SavingsCore.moneyNotSpent(localSeconds: stats.localAudioSeconds)
            return [
                "localAudioSeconds": stats.localAudioSeconds,
                "cloudAudioSeconds": stats.cloudAudioSeconds,
                "minutesSaved": minutesSaved,
                "moneySaved": moneySaved,
                "savingsWorthShowing": SavingsCore.isWorthShowing(
                    minutesSaved: minutesSaved,
                    moneySaved: moneySaved
                ),
                "readableTimeSaved": SavingsCore.readableDuration(minutes: minutesSaved),
                "readableMoneySaved": SavingsCore.readableMoney(moneySaved),
                "typingWordsPerMinute": SavingsCore.typingWordsPerMinute,
                "referenceCostPerMinute": SavingsCore.referenceTranscriptionCostPerMinute,
                "totalWords": stats.totalWords,
                "totalDictations": stats.totalDictations,
                "totalSpeakingSeconds": stats.totalSpeakingSeconds,
                "correctionsApplied": stats.correctionsApplied,
                "wordsPerMinute": stats.wordsPerMinute as Any? ?? NSNull(),
                "appsUsed": stats.wordsByApp.count,
                "wordsByApp": byApp,
                "dictationsByDay": stats.dictationsByDay,
                "currentStreak": UsageStatisticsCore.currentStreak(
                    days: stats.dictationsByDay,
                    today: Date()
                ),
                "longestStreak": UsageStatisticsCore.longestStreak(days: stats.dictationsByDay),
                "firstRecorded": stats.firstRecorded.map(Self.bridgeDateFormatter.string(from:)) as Any? ?? NSNull()
            ]
        }
        bridge.insightsResetHandler = { UsageStatisticsStore.shared.reset() }
        bridge.meetingHandler = { [weak self] action, body in
            guard let self else { return ["ok": false, "error": "ZFlow is not ready"] }
            return DispatchQueue.main.sync {
                let id = body["id"] as? String ?? ""
                switch action {
                case "create":
                    return self.createMeetingNote()
                case "list":
                    return ["ok": true, "items": self.meetingNotes()]
                case "get":
                    guard let note = self.meetingNote(id: id) else {
                        return ["ok": false, "error": "No such meeting."]
                    }
                    return ["ok": true, "note": note]
                case "finish":
                    let seconds = (body["durationSeconds"] as? NSNumber)?.doubleValue ?? 0
                    return ["ok": self.finishMeetingRecording(id: id, durationSeconds: seconds)]
                case "transcribe":
                    let turns = (body["turns"] as? [[String: Any]] ?? []).compactMap { entry -> SpeakerTurn? in
                        guard let speaker = (entry["speaker"] as? NSNumber)?.intValue,
                              let start = (entry["start"] as? NSNumber)?.doubleValue,
                              let end = (entry["end"] as? NSNumber)?.doubleValue else { return nil }
                        return SpeakerTurn(speaker: speaker, start: start, end: end)
                    }
                    return self.startMeetingTranscription(
                        id: id,
                        remoteTurns: TimedTranscriptCore.renumberingByFirstAppearance(turns)
                    )
                case "summarise":
                    return self.startMeetingSummary(id: id)
                case "rename":
                    let title = body["title"] as? String ?? ""
                    return ["ok": self.renameMeetingNote(id: id, title: title)]
                case "delete":
                    return ["ok": self.deleteMeetingNote(id: id)]
                default:
                    return ["ok": false, "error": "unknown action"]
                }
            }
        }
        bridge.fileTranscriptionStartHandler = { [weak self] path in
            guard let self else { return ["ok": false, "error": "ZFlow is not ready"] }
            return DispatchQueue.main.sync { self.startFileTranscription(path: path) }
        }
        bridge.fileTranscriptionStatusHandler = { [weak self] id in
            guard let self else { return nil }
            return DispatchQueue.main.sync { self.fileTranscriptionJob(id: id) }
        }
        bridge.screenshotHandler = { [weak self] id in
            guard let self else { return nil }
            return DispatchQueue.main.sync {
                self.pipelineHistory.first { $0.id.uuidString == id }?.contextScreenshotDataURL
            }
        }
        bridge.languagesHandler = { [weak self] in
            guard let self else { return [:] }
            return DispatchQueue.main.sync { self.bridgeLanguagePayload() }
        }

        // Asking Apple which languages it has is async, and the bridge answers
        // synchronously, so the answer is fetched once here and read from the
        // cache later. Done regardless of the current engine: the list has to
        // be right the moment someone switches to on-device.
        if #available(macOS 26.0, *) {
            Task { [weak self] in
                let supported = await LocalSpeechTranscriber.supportedLocaleIdentifiers()
                let installed = await LocalSpeechTranscriber.installedLocaleIdentifiers()
                guard let self else { return }
                await MainActor.run {
                    self.localTranscriptionSupportedLocales = supported
                    self.localTranscriptionInstalledLocales = installed
                }
            }
        }

        bridge.start()
    }

    /// Languages Apple's on-device transcriber can handle on this Mac, and
    /// which of them are downloaded. Empty until the query above returns.
    private var localTranscriptionSupportedLocales: [String] = []
    private var localTranscriptionInstalledLocales: [String] = []

    /// The dictation languages that are valid for the engine in use right now.
    ///
    /// The point is that the picker never offers a language the active engine
    /// would reject, and never hides one it supports.
    private func bridgeLanguagePayload() -> [String: Any] {
        let names = Self.transcriptionLanguageOptions
        let isLocal = transcriptionEngine == .local
        let localEntries = LanguageCatalog.localEntries(
            supportedLocaleIdentifiers: localTranscriptionSupportedLocales,
            installedLocaleIdentifiers: localTranscriptionInstalledLocales,
            names: names
        )
        // Only report the on-device list once it has actually arrived. An empty
        // list here means "not answered yet", not "no languages".
        let ready = !isLocal || !localEntries.isEmpty
        let entries = (isLocal && ready) ? localEntries : LanguageCatalog.cloudEntries(from: names)

        return [
            "engine": transcriptionEngine.rawValue,
            "ready": ready,
            "autoDetectLabel": isLocal ? "Use this Mac\'s language" : "Auto-detect",
            "autoDetectDesc": isLocal
                ? "Apple\'s on-device model transcribes one language at a time, so leaving this off follows this Mac\'s language."
                : "The provider works the language out from the audio. Pick one if you see the wrong script in your output.",
            "items": entries.map { entry -> [String: Any] in
                [
                    "code": entry.code,
                    "name": entry.name,
                    "nativeName": entry.nativeName,
                    "installed": entry.installed
                ]
            }
        ]
    }

    /// One formatter, not one per history row per request.
    static let bridgeDateFormatter = ISO8601DateFormatter()

    private func bridgeValue(forKey key: String) -> Any? {
        // A credential is never returned. The UI needs to know whether one is
        // set so it can say so; it never needs the value back.
        if SettingsBridgeContract.secretKeys.contains(key) {
            let stored = key == "api_key" ? apiKey : transcriptionAPIKey
            return stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "set"
        }

        switch key {
        case "transcription_engine": return transcriptionEngine.rawValue
        case "post_processing_engine": return postProcessingEngine.rawValue
        case "transcription_model": return transcriptionModel
        case "transcription_language": return transcriptionLanguage
        case "transcription_request_format": return transcriptionRequestFormat.rawValue
        case "api_base_url": return apiBaseURL
        case "post_processing_model": return postProcessingModel
        case "post_processing_fallback_model": return postProcessingFallbackModel
        case "context_model": return contextModel
        case "output_language": return outputLanguage
        case "post_processing_enabled": return postProcessingEnabled
        case "context_inference_enabled": return contextInferenceEnabled
        case "notetaker_engine": return notetakerEngine.rawValue
        case "context_screenshot_enabled": return contextScreenshotEnabled
        case "learned_corrections_enabled": return learnedCorrectionsEnabled
        case "correction_adjudication_enabled": return correctionAdjudicationEnabled
        case "preserve_exact_wording": return preserveExactWording
        case "instruction_execution_guard_enabled": return instructionExecutionGuardEnabled
        case "command_mode_enabled": return isCommandModeEnabled
        case "press_enter_voice_command_enabled": return isPressEnterVoiceCommandEnabled
        case "preserve_clipboard": return preserveClipboard
        case "keep_dictation_in_clipboard_history": return keepDictationInClipboardHistory
        case "alert_sounds_enabled": return alertSoundsEnabled
        case "dictation_audio_interruption_enabled": return dictationAudioInterruptionEnabled
        case "realtime_streaming_enabled": return realtimeStreamingEnabled
        case "launch_at_login": return launchAtLogin
        case "show_menu_bar_icon": return UserDefaults.standard.object(forKey: "show_menu_bar_icon") as? Bool ?? true
        case "show_app_in_dock": return DockVisibility.isEnabled
        case "use_compact_overlay": return UserDefaults.standard.object(forKey: "use_compact_overlay") as? Bool ?? true
        case "transcription_api_url": return transcriptionAPIURL
        case "realtime_streaming_model": return realtimeStreamingModel
        case "custom_vocabulary": return customVocabulary
        case "custom_system_prompt": return customSystemPrompt
        case "custom_context_prompt": return customContextPrompt
        case "sound_volume": return Double(soundVolume)
        case "shortcut_start_delay": return shortcutStartDelay
        case "context_screenshot_max_dimension": return contextScreenshotMaxDimension
        case "command_mode_style": return commandModeStyle.rawValue
        case "selected_microphone_id": return selectedMicrophoneID
        default: return nil
        }
    }

    @discardableResult
    private func applyBridgeValue(_ value: Any, forKey key: String) -> Bool {
        func boolValue() -> Bool? {
            if let flag = value as? Bool { return flag }
            if let number = value as? NSNumber { return number.boolValue }
            if let text = value as? String { return ["1", "true", "yes"].contains(text.lowercased()) }
            return nil
        }
        func stringValue() -> String? { value as? String }
        func doubleValue() -> Double? {
            if let number = value as? NSNumber { return number.doubleValue }
            if let text = value as? String { return Double(text) }
            return nil
        }

        if SettingsBridgeContract.secretKeys.contains(key) {
            guard let text = stringValue() else { return false }
            if key == "api_key" { apiKey = text } else { transcriptionAPIKey = text }
            return true
        }

        switch key {
        case "transcription_engine":
            guard let raw = stringValue() else { return false }
            transcriptionEngine = TranscriptionEngine.normalized(raw)
        case "post_processing_engine":
            guard let raw = stringValue() else { return false }
            postProcessingEngine = PostProcessingEngine.normalized(raw)
        case "transcription_request_format":
            guard let raw = stringValue() else { return false }
            transcriptionRequestFormat = TranscriptionRequestFormat.normalized(raw)
        case "transcription_model":
            guard let text = stringValue() else { return false }
            transcriptionModel = text
        case "transcription_language":
            guard let text = stringValue() else { return false }
            transcriptionLanguage = text
        case "api_base_url":
            guard let text = stringValue() else { return false }
            apiBaseURL = text
        case "post_processing_model":
            guard let text = stringValue() else { return false }
            postProcessingModel = text
        case "post_processing_fallback_model":
            guard let text = stringValue() else { return false }
            postProcessingFallbackModel = text
        case "context_model":
            guard let text = stringValue() else { return false }
            contextModel = text
        case "output_language":
            guard let text = stringValue() else { return false }
            outputLanguage = text
        case "post_processing_enabled":
            guard let flag = boolValue() else { return false }
            postProcessingEnabled = flag
        case "context_inference_enabled":
            guard let flag = boolValue() else { return false }
            contextInferenceEnabled = flag
        case "notetaker_engine":
            guard let raw = stringValue() else { return false }
            notetakerEngine = TranscriptionEngine.normalized(raw)
        case "context_screenshot_enabled":
            guard let flag = boolValue() else { return false }
            contextScreenshotEnabled = flag
        case "learned_corrections_enabled":
            guard let flag = boolValue() else { return false }
            learnedCorrectionsEnabled = flag
        case "correction_adjudication_enabled":
            guard let flag = boolValue() else { return false }
            correctionAdjudicationEnabled = flag
        case "preserve_exact_wording":
            guard let flag = boolValue() else { return false }
            preserveExactWording = flag
        case "instruction_execution_guard_enabled":
            guard let flag = boolValue() else { return false }
            instructionExecutionGuardEnabled = flag
        case "command_mode_enabled":
            guard let flag = boolValue() else { return false }
            isCommandModeEnabled = flag
        case "press_enter_voice_command_enabled":
            guard let flag = boolValue() else { return false }
            isPressEnterVoiceCommandEnabled = flag
        case "preserve_clipboard":
            guard let flag = boolValue() else { return false }
            preserveClipboard = flag
        case "keep_dictation_in_clipboard_history":
            guard let flag = boolValue() else { return false }
            keepDictationInClipboardHistory = flag
        case "alert_sounds_enabled":
            guard let flag = boolValue() else { return false }
            alertSoundsEnabled = flag
        case "dictation_audio_interruption_enabled":
            guard let flag = boolValue() else { return false }
            dictationAudioInterruptionEnabled = flag
        case "realtime_streaming_enabled":
            guard let flag = boolValue() else { return false }
            realtimeStreamingEnabled = flag
        case "launch_at_login":
            guard let flag = boolValue() else { return false }
            launchAtLogin = flag
        case "show_menu_bar_icon", "use_compact_overlay":
            guard let flag = boolValue() else { return false }
            UserDefaults.standard.set(flag, forKey: key)
        case "show_app_in_dock":
            guard let flag = boolValue() else { return false }
            UserDefaults.standard.set(flag, forKey: DockVisibility.storageKey)
            Task { @MainActor in DockVisibility.apply() }
        case "transcription_api_url":
            guard let text = stringValue() else { return false }
            transcriptionAPIURL = text
        case "realtime_streaming_model":
            guard let text = stringValue() else { return false }
            realtimeStreamingModel = text
        case "custom_vocabulary":
            guard let text = stringValue() else { return false }
            customVocabulary = text
        case "custom_system_prompt":
            guard let text = stringValue() else { return false }
            customSystemPrompt = text
        case "custom_context_prompt":
            guard let text = stringValue() else { return false }
            customContextPrompt = text
        case "selected_microphone_id":
            guard let text = stringValue() else { return false }
            selectedMicrophoneID = text
        case "command_mode_style":
            guard let raw = stringValue(), let style = CommandModeStyle(rawValue: raw) else { return false }
            commandModeStyle = style
        case "sound_volume":
            guard let number = doubleValue() else { return false }
            soundVolume = Float(max(0, min(1, number)))
        case "shortcut_start_delay":
            guard let number = doubleValue() else { return false }
            shortcutStartDelay = max(0, number)
        case "context_screenshot_max_dimension":
            guard let number = doubleValue() else { return false }
            contextScreenshotMaxDimension = Self.normalizedContextScreenshotMaxDimension(Int(number))
        default:
            return false
        }
        return true
    }

    private func installCorrectionWatcher() {
        correctionWatcher.onCorrectionDetected = { [weak self] correction in
            self?.learnCorrection(correction)
        }
        correctionWatcher.onUnrecognisedEdit = { [weak self] pasted, edited in
            self?.adjudicateEdit(pasted: pasted, edited: edited)
        }
    }

    /// Second opinion for an edit the rules could not classify.
    private func adjudicateEdit(pasted: String, edited: String) {
        guard learnedCorrectionsEnabled, correctionAdjudicationEnabled else { return }
        guard CorrectionAdjudicator.isWorthAsking(pasted: pasted, edited: edited) else {
            os_log(.info, log: recordingLog, "not asking the model: the edit is too large to be a spelling fix")
            return
        }

        let prompt = CorrectionAdjudicator.prompt(pasted: pasted, edited: edited)
        let engine = postProcessingEngine
        let service = PostProcessingService(
            apiKey: apiKey,
            baseURL: apiBaseURL,
            preferredModel: postProcessingModel,
            preferredFallbackModel: postProcessingFallbackModel,
            instructionExecutionGuardEnabled: instructionExecutionGuardEnabled
        )

        Task { [weak self] in
            guard let self else { return }
            let answer: String?
            if engine == .local, #available(macOS 26.0, *) {
                answer = try? await LocalTextProcessor.adjudicate(prompt: prompt)
            } else {
                answer = try? await service.adjudicate(prompt: prompt)
            }
            guard let answer else {
                os_log(.error, log: recordingLog, "correction adjudication failed")
                return
            }
            guard let correction = CorrectionAdjudicator.parseVerdict(answer) else {
                os_log(.info, log: recordingLog, "the model judged the edit not to be a spelling correction")
                return
            }
            await MainActor.run {
                self.learnCorrection(correction)
            }
        }
    }

    /// Records a word the user respelled, and offers an immediate undo: a rule
    /// learned by mistake would quietly rewrite every later dictation, so it
    /// must be one click to remove while the user still remembers why.
    private func learnCorrection(_ correction: WordCorrection) {
        guard learnedCorrectionsEnabled else { return }
        os_log(
            .info,
            log: recordingLog,
            "learned a correction: %ld characters became %ld",
            correction.original.count,
            correction.corrected.count
        )
        learnedCorrections = LearnedCorrectionStore.merging(correction, into: learnedCorrections)
        overlayManager.showInfoToast(
            "Added “\(correction.corrected)” to your dictionary — future dictations will use this spelling.",
            actionTitle: "Undo"
        ) { [weak self] in
            self?.forgetCorrection(id: correction.id)
        }
    }

    func forgetCorrection(id: String) {
        learnedCorrections = LearnedCorrectionStore.removingVariant(id: id, in: learnedCorrections)
    }

    /// The learned dictionary as the settings list shows it: one canonical
    /// spelling per row, with every heard form that maps onto it.
    var learnedWordGroups: [LearnedCorrectionStore.Group] {
        LearnedCorrectionStore.grouped(learnedCorrections)
    }

    func renameCorrectedSpelling(from oldValue: String, to newValue: String) {
        learnedCorrections = LearnedCorrectionStore.renamingCorrected(
            from: oldValue,
            to: newValue,
            in: learnedCorrections
        )
    }

    func renameHeardForm(id: String, to newValue: String) {
        learnedCorrections = LearnedCorrectionStore.replacingVariant(
            id: id,
            with: newValue,
            in: learnedCorrections
        )
    }

    func addHeardForm(_ original: String, correctedTo corrected: String) {
        learnedCorrections = LearnedCorrectionStore.addingVariant(
            original,
            correctedTo: corrected,
            in: learnedCorrections
        )
    }

    func forgetCorrectedSpelling(_ corrected: String) {
        learnedCorrections = LearnedCorrectionStore.removingGroup(
            corrected: corrected,
            in: learnedCorrections
        )
    }

    /// The vocabulary handed to the cleanup model, with the spellings the user
    /// has corrected appended. The deterministic pass afterwards is what
    /// guarantees the result; this only stops the model mangling the word in
    /// ways a word-boundary replacement could no longer repair.
    private var vocabularyIncludingLearnedSpellings: String {
        guard learnedCorrectionsEnabled, !learnedCorrections.isEmpty else { return customVocabulary }
        let learned = learnedCorrections.map(\.corrected).joined(separator: ", ")
        let base = customVocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? learned : base + ", " + learned
    }

    /// Rewrites a transcript with every learned spelling. Deterministic rather
    /// than left to the model, so corrections also apply when cleanup is off.
    /// The dictionary applied without touching the per-run counters, for work
    /// that is not a dictation.
    func applyingLearnedCorrections(_ transcript: String) -> String {
        guard learnedCorrectionsEnabled, !learnedCorrections.isEmpty else { return transcript }
        return LearnedCorrectionStore.applying(learnedCorrections, to: transcript)
    }

    private func applyLearnedCorrections(_ transcript: String) -> String {
        guard learnedCorrectionsEnabled, !learnedCorrections.isEmpty else { return transcript }
        let result = LearnedCorrectionStore.applying(learnedCorrections, to: transcript)
        // How many distinct learned words actually fired, for the usage
        // counts. Measured by re-running each one alone rather than by
        // guessing from the result, so overlapping rules are not counted
        // twice.
        if result != transcript {
            lastRunCorrectionsApplied = learnedCorrections.filter {
                LearnedCorrectionStore.applying([$0], to: transcript) != transcript
            }.count
        }
        return result
    }

    // MARK: Meetings

    /// Makes a note and tells the caller where to write its two tracks.
    func createMeetingNote() -> [String: Any] {
        guard let note = NotetakerStore.shared.create() else {
            return ["ok": false, "error": "ZFlow could not make a folder for the recording."]
        }
        guard let folder = NotetakerStore.shared.directory(for: note.id) else {
            return ["ok": false, "error": "ZFlow could not make a folder for the recording."]
        }
        return [
            "ok": true,
            "note": NotetakerStore.shared.payload(note),
            "micTrackPath": folder.appendingPathComponent(NotetakerCore.micTrackFileName).path,
            "systemTrackPath": folder.appendingPathComponent(NotetakerCore.systemTrackFileName).path
        ]
    }

    /// Summarises a finished meeting with whichever engine does text
    /// processing — the same one that cleans a dictation, and the same choice
    /// about whether anything leaves the machine.
    func startMeetingSummary(id: String) -> [String: Any] {
        guard let note = NotetakerStore.shared.load(id) else {
            return ["ok": false, "error": "No such meeting."]
        }
        guard MeetingSummaryCore.isWorthSummarising(note.transcript) else {
            return ["ok": false, "error": "There is not enough here to summarise."]
        }
        let prompt = MeetingSummaryCore.prompt(transcript: note.transcript, speakers: note.speakers)
        let engine = postProcessingEngine
        let service = PostProcessingService(
            apiKey: apiKey,
            baseURL: apiBaseURL,
            preferredModel: postProcessingModel,
            preferredFallbackModel: postProcessingFallbackModel,
            instructionExecutionGuardEnabled: instructionExecutionGuardEnabled
        )

        Task.detached {
            do {
                let raw: String
                switch engine {
                case .local:
                    guard #available(macOS 26.0, *) else {
                        throw FileTranscriptionError.localUnavailable
                    }
                    raw = try await LocalTextProcessor.adjudicate(prompt: prompt)
                case .cloud:
                    raw = try await service.adjudicate(prompt: prompt)
                }
                let summary = MeetingSummaryCore.cleaned(raw)
                await MainActor.run {
                    guard var saved = NotetakerStore.shared.load(id) else { return }
                    saved.summary = summary
                    NotetakerStore.shared.save(saved)
                }
            } catch {
                await MainActor.run {
                    guard var saved = NotetakerStore.shared.load(id) else { return }
                    saved.errorMessage = "The summary did not come back: " + Self.fileTranscriptionMessage(for: error)
                    NotetakerStore.shared.save(saved)
                }
            }
        }
        return ["ok": true]
    }

    func meetingNotes() -> [[String: Any]] {
        NotetakerStore.shared.all().map(NotetakerStore.shared.payload)
    }

    func meetingNote(id: String) -> [String: Any]? {
        NotetakerStore.shared.load(id).map(NotetakerStore.shared.payload)
    }

    func renameMeetingNote(id: String, title: String) -> Bool {
        guard var note = NotetakerStore.shared.load(id) else { return false }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        note.title = trimmed
        NotetakerStore.shared.save(note)
        return true
    }

    func deleteMeetingNote(id: String) -> Bool {
        NotetakerStore.shared.delete(id)
    }

    /// Records how long the meeting ran, once the tracks are on disk.
    func finishMeetingRecording(id: String, durationSeconds: Double) -> Bool {
        guard var note = NotetakerStore.shared.load(id) else { return false }
        note.durationSeconds = durationSeconds
        note.state = .recorded
        NotetakerStore.shared.save(note)
        return true
    }

    /// Transcribes both tracks and assembles the conversation.
    ///
    /// `diarize` is handed in rather than done here: the speaker models live in
    /// the front end, which is where the ONNX runtime is, so Swift asks for
    /// turns and does not care how they were found.
    func startMeetingTranscription(id: String, remoteTurns: [SpeakerTurn]) -> [String: Any] {
        guard var note = NotetakerStore.shared.load(id) else {
            return ["ok": false, "error": "No such meeting."]
        }
        guard note.state != .transcribing else {
            return ["ok": true, "note": NotetakerStore.shared.payload(note)]
        }
        note.state = .transcribing
        note.errorMessage = ""
        NotetakerStore.shared.save(note)

        let engine = notetakerEngine
        let language = transcriptionLanguage
        let micURL = NotetakerStore.shared.trackURL(for: id, named: NotetakerCore.micTrackFileName)
        let systemURL = NotetakerStore.shared.trackURL(for: id, named: NotetakerCore.systemTrackFileName)

        Task.detached { [weak self] in
            guard let owner = self else { return }
            let cloudFactory: () throws -> TranscriptionService = {
                try DispatchQueue.main.sync { try owner.makeTranscriptionService() }
            }
            do {
                var mic: [TranscriptSegment] = []
                var remote: [TranscriptSegment] = []
                if let micURL {
                    mic = try await NotetakerService.transcribeTrack(
                        at: micURL,
                        speaker: NotetakerCore.youLabel,
                        engine: engine,
                        languageCode: language,
                        cloudService: cloudFactory,
                        onProgress: { _ in }
                    )
                }
                if let systemURL {
                    // The far side is cut where the speaker changes, so a
                    // window never covers two people and get credited to one.
                    let boundaries = remoteTurns.flatMap { [$0.start, $0.end] }
                    remote = try await NotetakerService.transcribeTrack(
                        at: systemURL,
                        speaker: NotetakerCore.remoteLabel,
                        engine: engine,
                        languageCode: language,
                        cloudService: cloudFactory,
                        boundaries: boundaries,
                        onProgress: { _ in }
                    )
                }
                let processed = NotetakerService.transcribedSeconds(mic) + NotetakerService.transcribedSeconds(remote)
                UsageStatisticsStore.shared.update { stats in
                    UsageStatisticsCore.recordingMeetingAudio(
                        stats,
                        seconds: processed,
                        onDevice: engine == .local
                    )
                }

                let outcome = NotetakerService.assemble(
                    mic: mic,
                    remote: remote,
                    remoteTurns: remoteTurns,
                    engine: engine
                )
                let corrected = await MainActor.run { owner.applyingLearnedCorrections(outcome.transcript) }
                await MainActor.run {
                    guard var saved = NotetakerStore.shared.load(id) else { return }
                    saved.segments = outcome.segments.map {
                        MeetingNote.StoredSegment(speaker: $0.speaker, text: $0.text, start: $0.start, end: $0.end)
                    }
                    saved.transcript = corrected
                    saved.speakers = outcome.speakers
                    saved.engine = outcome.engine
                    saved.state = corrected.isEmpty ? .failed : .ready
                    if corrected.isEmpty {
                        saved.errorMessage = "No speech was found in that recording."
                    } else if let opening = outcome.segments.first?.text,
                              let suggested = NotetakerCore.suggestedTitle(from: opening),
                              saved.title.hasPrefix("Meeting on ") {
                        saved.title = suggested
                    }
                    NotetakerStore.shared.save(saved)
                }
            } catch {
                await MainActor.run {
                    guard var saved = NotetakerStore.shared.load(id) else { return }
                    saved.state = .failed
                    saved.errorMessage = Self.fileTranscriptionMessage(for: error)
                    NotetakerStore.shared.save(saved)
                }
            }
        }

        return ["ok": true, "note": NotetakerStore.shared.payload(note)]
    }

    /// Files dropped in for transcription, by job id. Kept in memory only:
    /// a job that did not survive a relaunch was not worth resuming.
    private var fileTranscriptionJobs: [String: FileTranscriptionCore.Job] = [:]

    /// Starts transcribing a dropped file through whichever engine is already
    /// configured, and answers immediately with a job to poll.
    ///
    /// Immediately, because an hour of audio takes minutes and no HTTP request
    /// should be held open that long.
    func startFileTranscription(path: String) -> [String: Any] {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        let exists = FileManager.default.fileExists(atPath: path)
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0

        if let refusal = FileTranscriptionCore.refusal(forName: name, sizeInBytes: size, exists: exists) {
            return ["ok": false, "error": refusal.message]
        }

        let id = UUID().uuidString
        let seconds = FileTranscriptionService.audioDurationSeconds(of: url)
        let engine = transcriptionEngine
        var job = FileTranscriptionCore.Job(id: id, fileName: name)
        job.engine = engine.rawValue
        job.audioSeconds = seconds
        fileTranscriptionJobs[id] = job

        let language = transcriptionLanguage
        Task.detached { [weak self] in
            guard let owner = self else { return }
            func finish(_ state: FileTranscriptionCore.JobState) async {
                await MainActor.run { owner.updateFileTranscriptionJob(id: id, state: state) }
            }
            do {
                let transcript: String
                switch engine {
                case .local:
                    guard #available(macOS 26.0, *) else {
                        throw FileTranscriptionError.localUnavailable
                    }
                    transcript = try await FileTranscriptionService.transcribeLocally(
                        url: url,
                        languageCode: language
                    ) { progress in
                        Task { @MainActor in
                            owner.updateFileTranscriptionJob(id: id, state: .running(progress: progress))
                        }
                    }
                case .cloud:
                    let service = try await MainActor.run { try owner.makeTranscriptionService() }
                    transcript = try await service.transcribe(fileURL: url)
                }
                // The user's own dictionary, applied the same way it is to a
                // dictation. Nothing else rewrites the text: a dropped
                // recording is a record of what was said.
                let corrected = await MainActor.run { owner.applyingLearnedCorrections(transcript) }
                await finish(.finished(transcript: corrected))
            } catch {
                await finish(.failed(message: Self.fileTranscriptionMessage(for: error)))
            }
        }

        return ["ok": true, "job": job.payload]
    }

    private static func fileTranscriptionMessage(for error: Error) -> String {
        if let readable = error as? FileTranscriptionError {
            return readable.errorDescription ?? "\(error)"
        }
        if let short = error as? ShortDisplayableError {
            return short.shortDisplayMessage
        }
        return error.localizedDescription
    }

    private func updateFileTranscriptionJob(id: String, state: FileTranscriptionCore.JobState) {
        guard var job = fileTranscriptionJobs[id] else { return }
        // A finished job is final: a late progress callback must not reopen it.
        if case .running = job.state {} else if case .running = state { return }
        job.state = state
        fileTranscriptionJobs[id] = job
    }

    func fileTranscriptionJob(id: String) -> [String: Any]? {
        fileTranscriptionJobs[id]?.payload
    }

    /// Set by the last dictation, read once when its history entry is written.
    private var lastRunCorrectionsApplied = 0
    /// When the current dictation started, for the speaking-pace figure.
    private var dictationStartedAt: Date?

    private func installAudioDeviceObservers() {
        removeAudioDeviceObservers()

        let notificationCenter = NotificationCenter.default
        let refreshOnAudioDeviceChange: (Notification) -> Void = { [weak self] notification in
            guard let device = notification.object as? AVCaptureDevice,
                  device.hasMediaType(.audio) else {
                return
            }
            self?.refreshAvailableMicrophones()
        }

        audioDeviceObservers.append(
            notificationCenter.addObserver(
                forName: .AVCaptureDeviceWasConnected,
                object: nil,
                queue: .main,
                using: refreshOnAudioDeviceChange
            )
        )
        audioDeviceObservers.append(
            notificationCenter.addObserver(
                forName: .AVCaptureDeviceWasDisconnected,
                object: nil,
                queue: .main,
                using: refreshOnAudioDeviceChange
            )
        )
    }

    var usesFnShortcut: Bool {
        holdShortcut.usesFnKey || toggleShortcut.usesFnKey || copyAgainShortcut.usesFnKey
    }

    var hasEnabledHoldShortcut: Bool {
        !holdShortcut.isDisabled
    }

    var hasEnabledToggleShortcut: Bool {
        !toggleShortcut.isDisabled
    }

    var shortcutStatusText: String {
        if hotkeyMonitoringErrorMessage != nil {
            return "Global shortcuts unavailable"
        }

        switch (hasEnabledHoldShortcut, hasEnabledToggleShortcut) {
        case (true, true):
            return "Hold \(holdShortcut.displayName) or tap \(toggleShortcut.displayName) to dictate"
        case (true, false):
            return "Hold \(holdShortcut.displayName) to dictate"
        case (false, true):
            return "Tap \(toggleShortcut.displayName) to dictate"
        case (false, false):
            return "No dictation shortcut enabled"
        }
    }

    var shortcutStartDelayMilliseconds: Int {
        Int((shortcutStartDelay * 1000).rounded())
    }

    func savedCustomShortcut(for role: ShortcutRole) -> ShortcutBinding? {
        switch role {
        case .hold:
            return savedHoldCustomShortcut
        case .toggle:
            return savedToggleCustomShortcut
        case .copyAgain:
            return savedCopyAgainCustomShortcut
        }
    }

    var commandModeManualModifierValidationMessage: String? {
        guard isCommandModeEnabled, commandModeStyle == .manual else { return nil }
        return commandModeManualModifierCollisionMessage(for: commandModeManualModifier)
    }

    @discardableResult
    func setCommandModeEnabled(_ enabled: Bool) -> String? {
        isCommandModeEnabled = enabled
        if enabled, commandModeStyle == .manual {
            return commandModeManualModifierCollisionMessage(for: commandModeManualModifier)
        }
        return nil
    }

    @discardableResult
    func setCommandModeStyle(_ style: CommandModeStyle) -> String? {
        commandModeStyle = style
        if isCommandModeEnabled, style == .manual {
            return commandModeManualModifierCollisionMessage(for: commandModeManualModifier)
        }
        return nil
    }

    @discardableResult
    func setCommandModeManualModifier(_ modifier: CommandModeManualModifier) -> String? {
        // Match sibling setters: always commit, then validate.
        commandModeManualModifier = modifier
        if isCommandModeEnabled, commandModeStyle == .manual {
            return commandModeManualModifierCollisionMessage(for: modifier)
        }
        return nil
    }

    @discardableResult
    func setShortcut(_ binding: ShortcutBinding, for role: ShortcutRole) -> String? {
        let binding = binding.normalizedForStorageMigration()

        if role == .hold || role == .toggle {
            let otherDictationBinding = role == .hold ? toggleShortcut : holdShortcut
            guard !binding.conflicts(with: otherDictationBinding) else {
                return "Hold and tap shortcuts must be distinct."
            }
        }

        if role != .copyAgain, binding.conflicts(with: copyAgainShortcut) {
            return "This shortcut is already used by Paste Again."
        }
        if role == .copyAgain {
            if binding.conflicts(with: holdShortcut) {
                return "Paste Again cannot share a shortcut with Hold to Talk."
            }
            if binding.conflicts(with: toggleShortcut) {
                return "Paste Again cannot share a shortcut with Tap to Toggle."
            }
            if isCommandModeEnabled, commandModeStyle == .manual,
               bindingCollides(binding, with: commandModeManualModifier) {
                return "Paste Again cannot share the Edit Mode modifier."
            }
        }

        switch role {
        case .hold:
            if binding.isCustom {
                savedHoldCustomShortcut = binding
            }
            holdShortcut = binding
        case .toggle:
            if binding.isCustom {
                savedToggleCustomShortcut = binding
            }
            toggleShortcut = binding
        case .copyAgain:
            if binding.isCustom {
                savedCopyAgainCustomShortcut = binding
            }
            copyAgainShortcut = binding
        }

        return nil
    }

    private func commandModeManualModifierCollisionMessage(
        for modifier: CommandModeManualModifier,
        holdBinding: ShortcutBinding? = nil,
        toggleBinding: ShortcutBinding? = nil,
        copyAgainBinding: ShortcutBinding? = nil
    ) -> String? {
        let holdBinding = holdBinding ?? holdShortcut
        let toggleBinding = toggleBinding ?? toggleShortcut
        let copyAgainBinding = copyAgainBinding ?? copyAgainShortcut
        let manualModifier = modifier.shortcutModifier

        if !holdBinding.isDisabled && holdBinding.modifiers.contains(manualModifier) {
            return "That modifier is already part of the hold shortcut."
        }
        if !toggleBinding.isDisabled && toggleBinding.modifiers.contains(manualModifier) {
            return "That modifier is already part of the tap shortcut."
        }
        if !copyAgainBinding.isDisabled && copyAgainBinding.modifiers.contains(manualModifier) {
            return "That modifier is already part of the Paste Again shortcut."
        }
        // Modifier-only bindings carry identity in keyCode, not modifiers.
        if !holdBinding.isDisabled,
           holdBinding.kind == .modifierKey,
           let bindingModifier = ShortcutBinding.modifier(forKeyCode: holdBinding.keyCode),
           bindingModifier == manualModifier {
            return "That modifier is already the hold shortcut."
        }
        if !toggleBinding.isDisabled,
           toggleBinding.kind == .modifierKey,
           let bindingModifier = ShortcutBinding.modifier(forKeyCode: toggleBinding.keyCode),
           bindingModifier == manualModifier {
            return "That modifier is already the tap shortcut."
        }
        if !copyAgainBinding.isDisabled,
           copyAgainBinding.kind == .modifierKey,
           let bindingModifier = ShortcutBinding.modifier(forKeyCode: copyAgainBinding.keyCode),
           bindingModifier == manualModifier {
            return "That modifier is already the Paste Again shortcut."
        }

        return nil
    }

    private func bindingCollides(_ binding: ShortcutBinding, with modifier: CommandModeManualModifier) -> Bool {
        guard !binding.isDisabled else { return false }
        let manualModifier = modifier.shortcutModifier
        if binding.modifiers.contains(manualModifier) { return true }
        if binding.kind == .modifierKey,
           let bindingModifier = ShortcutBinding.modifier(forKeyCode: binding.keyCode),
           bindingModifier == manualModifier {
            return true
        }
        return false
    }

    func startHotkeyMonitoring() {
        shouldMonitorHotkeys = true
        hotkeyManager.onShortcutEvent = { [weak self] event in
            DispatchQueue.main.async {
                self?.handleShortcutEvent(event)
            }
        }
        hotkeyManager.onEscapeKeyPressed = { [weak self] in
            self?.handleEscapeKeyPress() ?? false
        }
        restartHotkeyMonitoring()
    }

    func stopHotkeyMonitoring() {
        shouldMonitorHotkeys = false
        hotkeyMonitoringErrorMessage = nil
        hotkeyManager.onShortcutEvent = nil
        hotkeyManager.onEscapeKeyPressed = nil
        hotkeyManager.stop()
    }

    func suspendHotkeyMonitoringForShortcutCapture() {
        isCapturingShortcut = true
        restartHotkeyMonitoring()
    }

    func resumeHotkeyMonitoringAfterShortcutCapture() {
        isCapturingShortcut = false
        restartHotkeyMonitoring()
    }

    private var activeShortcutConfiguration: ShortcutConfiguration {
        let permittedAdditionalExactMatchModifiers: ShortcutModifiers
        if isCommandModeEnabled, commandModeStyle == .manual {
            permittedAdditionalExactMatchModifiers = commandModeManualModifier.shortcutModifier
        } else {
            permittedAdditionalExactMatchModifiers = []
        }

        return ShortcutConfiguration(
            hold: holdShortcut,
            toggle: toggleShortcut,
            copyAgain: copyAgainShortcut,
            permittedAdditionalExactMatchModifiers: permittedAdditionalExactMatchModifiers
        )
    }

    private func restartHotkeyMonitoring() {
        guard hotkeyMonitoringWanted else {
            hotkeyManager.stop()
            return
        }

        do {
            try hotkeyManager.start(configuration: activeShortcutConfiguration)
            hotkeyMonitoringErrorMessage = nil
        } catch {
            hotkeyMonitoringErrorMessage = error.localizedDescription
            os_log(.error, log: recordingLog, "Hotkey monitoring failed to start: %{public}@", error.localizedDescription)
            // Tried again as soon as macOS would allow it, rather than left
            // dead until the next launch. Later, not from here: this can run
            // inside the watch's own check, and restarting the watch from
            // there would retry, fail and restart without end.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.accessibilityTimer == nil else { return }
                self.startAccessibilityPolling()
            }
        }
    }

    private func handleShortcutEvent(_ event: ShortcutEvent) {
        if event == .copyAgainTriggered {
            copyLastTranscriptToPasteboard()
            return
        }

        guard let action = shortcutSessionController.handle(event: event, isTranscribing: isTranscribing) else {
            return
        }

        switch action {
        case .start(let mode):
            os_log(.info, log: recordingLog, "Shortcut start fired for mode %{public}@", mode.rawValue)
            scheduleShortcutStart(mode: mode)
        case .stop:
            cancelPendingShortcutStart()
            guard isRecording else {
                shortcutSessionController.reset()
                activeRecordingTriggerMode = nil
                return
            }
            stopAndTranscribe()
        case .switchedToToggle:
            if isRecording {
                activeRecordingTriggerMode = .toggle
                overlayManager.setRecordingTriggerMode(.toggle, animated: true)
            } else if pendingShortcutStartMode != nil {
                pendingShortcutStartMode = .toggle
            }
        }
    }

    private func handleEscapeKeyPress() -> Bool {
        if isTranscribing {
            cancelTranscription()
            return true
        }

        if pendingShortcutStartMode == .toggle || activeRecordingTriggerMode == .toggle {
            cancelToggleShortcutSession()
            return true
        }

        return false
    }

    /// Copies the last transcript to the pasteboard and pastes it into the
    /// focused app — Wispr Flow style. Reuses the dictation paste pipeline so
    /// preserveClipboard is honored and the synthetic Cmd+V waits for the
    /// trigger shortcut to be fully released.
    func copyLastTranscriptToPasteboard() {
        guard !lastTranscript.isEmpty else { return }
        let pendingClipboardRestore = writeTranscriptToPasteboard(lastTranscript)
        pasteAtCursorWhenShortcutReleased { [weak self] in
            self?.restoreClipboardIfNeeded(pendingClipboardRestore)
        }
    }

    func toggleRecording() {
        os_log(.info, log: recordingLog, "toggleRecording() called, isRecording=%{public}d", isRecording)
        cancelPendingShortcutStart()
        if isRecording {
            stopAndTranscribe()
        } else {
            shortcutSessionController.beginManual(mode: .toggle)
            startRecording(triggerMode: .toggle)
        }
    }

    private func handleOverlayStopButtonPressed() {
        guard isRecording, activeRecordingTriggerMode == .toggle else { return }
        stopAndTranscribe()
    }

    private func cancelToggleShortcutSession() {
        guard pendingShortcutStartMode == .toggle || activeRecordingTriggerMode == .toggle else { return }

        cancelPendingShortcutStart()
        shortcutSessionController.reset()
        activeRecordingTriggerMode = nil
        audioRecorder.onRecordingReady = nil
        audioRecorder.onRecordingFailure = nil
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil
        cancelRecordingInitializationTimer()
        contextCaptureTask?.cancel()
        contextCaptureTask = nil
        capturedContext = nil
        currentSessionIntent = .dictation
        isRecording = false
        errorMessage = nil
        debugStatusMessage = "Cancelled"
        statusText = "Cancelled"
        overlayManager.dismiss()
        tearDownRealtimeService()
        audioRecorder.cancelRecording()
        restoreAudioInterruptionIfNeeded()
        endCriticalDictationActivity()
        refreshAvailableMicrophonesIfNeeded()
        if !isRecording && !isTranscribing && statusText == "Cancelled" {
            scheduleReadyStatusReset(after: 2, matching: ["Cancelled"])
        }
    }

    private func cancelTranscription() {
        guard isTranscribing else { return }

        transcriptionTask?.cancel()
        transcriptionTask = nil
        contextCaptureTask?.cancel()
        contextCaptureTask = nil
        capturedContext = nil
        shortcutSessionController.reset()
        activeRecordingTriggerMode = nil
        currentSessionIntent = .dictation
        isRecording = false
        isTranscribing = false
        errorMessage = nil
        debugStatusMessage = "Cancelled"
        statusText = "Cancelled"
        overlayManager.dismiss()
        audioRecorder.cleanup()
        if let transcribingAudioFileName {
            Self.deleteAudioFile(transcribingAudioFileName)
            self.transcribingAudioFileName = nil
        }
        endCriticalDictationActivity()
        refreshAvailableMicrophonesIfNeeded()
        if !isRecording && !isTranscribing && statusText == "Cancelled" {
            scheduleReadyStatusReset(after: 2, matching: ["Cancelled"])
        }
    }

    private func scheduleShortcutStart(mode: RecordingTriggerMode) {
        cancelPendingShortcutStart(resetMode: false)
        pendingSelectionSnapshot = contextService.collectSelectionSnapshot()
        pendingManualCommandInvocation = hotkeyManager.currentPressedModifiers.contains(
            commandModeManualModifier.shortcutModifier
        )
        pendingShortcutStartMode = mode
        let delay = shortcutStartDelay

        guard delay > 0 else {
            pendingShortcutStartMode = nil
            startRecording(triggerMode: mode)
            return
        }

        pendingShortcutStartTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }

            await MainActor.run { [weak self] in
                guard let self, let pendingMode = self.pendingShortcutStartMode else { return }
                self.pendingShortcutStartTask = nil
                self.pendingShortcutStartMode = nil
                self.startRecording(triggerMode: pendingMode)
            }
        }
    }

    private func cancelPendingShortcutStart(resetMode: Bool = true) {
        pendingShortcutStartTask?.cancel()
        pendingShortcutStartTask = nil
        pendingSelectionSnapshot = nil
        pendingManualCommandInvocation = false
        if resetMode {
            pendingShortcutStartMode = nil
        }
    }

    private func resolveSessionIntent(
        triggerMode: RecordingTriggerMode,
        selectionSnapshot: AppSelectionSnapshot,
        manualCommandRequested: Bool
    ) -> SessionIntent? {
        guard isCommandModeEnabled else {
            return .dictation
        }

        let rawSelectedText = selectionSnapshot.selectedText ?? ""
        let trimmedSelectedText = rawSelectedText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch commandModeStyle {
        case .automatic:
            if !trimmedSelectedText.isEmpty {
                return .command(invocation: .automatic, selectedText: rawSelectedText)
            }
            return .dictation
        case .manual:
            // If the binding IS the manual modifier, the "modifier pressed"
            // signal is the binding's own press. Fall back to plain dictation.
            let activeBinding: ShortcutBinding = (triggerMode == .toggle) ? toggleShortcut : holdShortcut
            if activeBinding.kind == .modifierKey,
               let bindingModifier = ShortcutBinding.modifier(forKeyCode: activeBinding.keyCode),
               bindingModifier == commandModeManualModifier.shortcutModifier {
                return .dictation
            }
            if let message = commandModeManualModifierCollisionMessage(for: commandModeManualModifier) {
                rejectInvalidCommandModeModifier(triggerMode: triggerMode, message: message)
                return nil
            }
            guard manualCommandRequested else {
                return .dictation
            }
            guard !trimmedSelectedText.isEmpty else {
                rejectCommandModeSelectionRequirement(triggerMode: triggerMode)
                return nil
            }
            return .command(invocation: .manual, selectedText: rawSelectedText)
        }
    }

    private func rejectCommandModeSelectionRequirement(triggerMode: RecordingTriggerMode) {
        currentSessionIntent = .dictation
        activeRecordingTriggerMode = nil
        pendingSelectionSnapshot = nil
        pendingManualCommandInvocation = false
        errorMessage = "Select text to transform first."
        statusText = "Select text to transform first"
        debugStatusMessage = "Edit mode requires selected text"
        shortcutSessionController.reset()
        if triggerMode == .toggle {
            cancelPendingShortcutStart()
        }
        playAlertSound(named: "Basso")
        scheduleReadyStatusReset(after: 2, matching: ["Select text to transform first"])
    }

    private func rejectInvalidCommandModeModifier(triggerMode: RecordingTriggerMode, message: String) {
        currentSessionIntent = .dictation
        activeRecordingTriggerMode = nil
        pendingSelectionSnapshot = nil
        pendingManualCommandInvocation = false
        errorMessage = message
        statusText = "Fix Edit Mode modifier"
        debugStatusMessage = "Edit mode modifier conflicts with dictation shortcuts"
        shortcutSessionController.reset()
        if triggerMode == .toggle {
            cancelPendingShortcutStart()
        }
        playAlertSound(named: "Basso")
        scheduleReadyStatusReset(after: 2, matching: ["Fix Edit Mode modifier"])
    }

    private func startRecording(triggerMode: RecordingTriggerMode) {
        let t0 = CFAbsoluteTimeGetCurrent()
        os_log(.info, log: recordingLog, "startRecording() entered")
        guard !isRecording && !isTranscribing else { return }
        // Before anything else: the previous dictation's correction watch is
        // reading another app's Accessibility tree, and that must not compete
        // with getting this recording started.
        stopWatchingForCorrections()

        dictationStartedAt = Date()
        lastRunCorrectionsApplied = 0
        let scheduledSelectionSnapshot = pendingSelectionSnapshot
        let scheduledManualCommandInvocation = pendingManualCommandInvocation
        cancelPendingShortcutStart()
        guard prepareRecordingStart(
            triggerMode: triggerMode,
            selectionSnapshot: scheduledSelectionSnapshot,
            manualCommandRequested: scheduledSelectionSnapshot == nil
                ? hotkeyManager.currentPressedModifiers.contains(commandModeManualModifier.shortcutModifier)
                : scheduledManualCommandInvocation,
            startedAt: t0
        ) else { return }
        guard ensureMicrophoneAccess() else { return }
        os_log(.info, log: recordingLog, "mic access check passed: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        applyAudioInterruptionIfNeeded()
        beginRecording(triggerMode: triggerMode)
        os_log(.info, log: recordingLog, "startRecording() finished: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
    }

    private func prepareRecordingStart(
        triggerMode: RecordingTriggerMode,
        selectionSnapshot: AppSelectionSnapshot? = nil,
        manualCommandRequested: Bool? = nil,
        startedAt: CFAbsoluteTime? = nil
    ) -> Bool {
        activeRecordingTriggerMode = triggerMode
        let isAccessibilityTrusted = AXIsProcessTrusted()
        hasAccessibility = isAccessibilityTrusted
        guard isAccessibilityTrusted else {
            errorMessage = "Accessibility permission required. Grant access in System Settings > Privacy & Security > Accessibility."
            statusText = "No Accessibility"
            activeRecordingTriggerMode = nil
            currentSessionIntent = .dictation
            shortcutSessionController.reset()
            showAccessibilityAlert()
            return false
        }
        if let startedAt {
            os_log(.info, log: recordingLog, "accessibility check passed: %.3fms", (CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
        }

        let selectionSnapshot = selectionSnapshot ?? contextService.collectSelectionSnapshot()
        let manualCommandRequested = manualCommandRequested
            ?? hotkeyManager.currentPressedModifiers.contains(commandModeManualModifier.shortcutModifier)
        guard let resolvedIntent = resolveSessionIntent(
            triggerMode: triggerMode,
            selectionSnapshot: selectionSnapshot,
            manualCommandRequested: manualCommandRequested
        ) else { return false }

        if resolvedIntent.isCommandMode {
            guard ensureScreenCaptureAccess() else { return false }
            if let startedAt {
                os_log(.info, log: recordingLog, "screen capture check passed: %.3fms", (CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
            }
        } else {
            hasScreenRecordingPermission = hasScreenCapturePermission()
        }

        currentSessionIntent = resolvedIntent
        overlayManager.setRecordingTriggerMode(triggerMode, animated: false)
        return true
    }

    private func ensureScreenCaptureAccess() -> Bool {
        let granted = hasScreenCapturePermission()
        hasScreenRecordingPermission = granted
        guard granted else {
            let message = "Screen recording permission not granted. Enable in System Settings > Privacy & Security > Screen Recording."
            errorMessage = message
            statusText = "Screenshot Required"
            activeRecordingTriggerMode = nil
            currentSessionIntent = .dictation
            shortcutSessionController.reset()
            playAlertSound(named: "Basso")
            showScreenshotPermissionAlert(message: message)
            return false
        }

        return true
    }

    private func ensureMicrophoneAccess() -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            guard let triggerMode = activeRecordingTriggerMode else {
                return false
            }

            prepareForMicrophonePermissionPrompt(
                triggerMode: triggerMode,
                selectionSnapshot: pendingSelectionSnapshot ?? contextService.collectSelectionSnapshot(),
                manualCommandRequested: currentSessionIntent.isManualCommand
            )
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let strongSelf = self else { return }
                    let pendingTriggerMode = strongSelf.pendingMicrophonePermissionTriggerMode
                    let pendingSelectionSnapshot = strongSelf.pendingMicrophonePermissionSelectionSnapshot
                    let pendingManualCommandRequested = strongSelf.pendingMicrophonePermissionManualCommandRequested
                    strongSelf.pendingMicrophonePermissionTriggerMode = nil
                    strongSelf.pendingMicrophonePermissionSelectionSnapshot = nil
                    strongSelf.pendingMicrophonePermissionManualCommandRequested = nil
                    strongSelf.isAwaitingMicrophonePermission = false
                    strongSelf.restartHotkeyMonitoring()

                    guard let triggerMode = pendingTriggerMode else { return }
                    if granted {
                        strongSelf.errorMessage = nil
                        if triggerMode == .toggle {
                            guard strongSelf.prepareRecordingStart(
                                triggerMode: .toggle,
                                selectionSnapshot: pendingSelectionSnapshot,
                                manualCommandRequested: pendingManualCommandRequested
                            ) else { return }
                            strongSelf.shortcutSessionController.beginManual(mode: .toggle)
                            strongSelf.applyAudioInterruptionIfNeeded()
                            strongSelf.beginRecording(triggerMode: .toggle)
                        } else {
                            strongSelf.currentSessionIntent = .dictation
                            strongSelf.statusText = "Microphone access granted. Press and hold again to record."
                            strongSelf.scheduleReadyStatusReset(
                                after: 2,
                                matching: ["Microphone access granted. Press and hold again to record."]
                            )
                        }
                    } else {
                        strongSelf.errorMessage = "Microphone permission denied. Grant access in System Settings > Privacy & Security > Microphone."
                        strongSelf.statusText = "No Microphone"
                        strongSelf.activeRecordingTriggerMode = nil
                        strongSelf.currentSessionIntent = .dictation
                        strongSelf.shortcutSessionController.reset()
                        strongSelf.showMicrophonePermissionAlert()
                    }
                }
            }
            return false
        default:
            errorMessage = "Microphone permission denied. Grant access in System Settings > Privacy & Security > Microphone."
            statusText = "No Microphone"
            activeRecordingTriggerMode = nil
            currentSessionIntent = .dictation
            shortcutSessionController.reset()
            showMicrophonePermissionAlert()
            return false
        }
    }

    private func prepareForMicrophonePermissionPrompt(
        triggerMode: RecordingTriggerMode,
        selectionSnapshot: AppSelectionSnapshot?,
        manualCommandRequested: Bool?
    ) {
        isAwaitingMicrophonePermission = true
        pendingMicrophonePermissionTriggerMode = triggerMode
        pendingMicrophonePermissionSelectionSnapshot = selectionSnapshot
        pendingMicrophonePermissionManualCommandRequested = manualCommandRequested
        hotkeyManager.stop()
        shortcutSessionController.reset()
        activeRecordingTriggerMode = nil
        cancelRecordingInitializationTimer()
        audioRecorder.onRecordingReady = nil
        audioRecorder.onRecordingFailure = nil
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil
        overlayManager.dismiss()
    }

    private func applyAudioInterruptionIfNeeded() {
        guard dictationAudioInterruptionEnabled, activeAudioInterruption == nil else { return }

        let wasMuted = SystemAudioStatus.isDefaultOutputMuted()
        if wasMuted {
            activeAudioInterruption = .muted(previouslyMuted: true)
        } else if SystemAudioStatus.setDefaultOutputMuted(true) {
            activeAudioInterruption = .muted(previouslyMuted: false)
        }
    }

    private func restoreAudioInterruptionIfNeeded() {
        guard let activeAudioInterruption else { return }
        self.activeAudioInterruption = nil

        switch activeAudioInterruption {
        case .muted(let previouslyMuted):
            if !previouslyMuted {
                _ = SystemAudioStatus.setDefaultOutputMuted(false)
            }
        }
    }

    private func beginCriticalDictationActivity() {
        guard !automaticTerminationDisabled else { return }
        ProcessInfo.processInfo.disableAutomaticTermination("ZFlow dictation in progress")
        automaticTerminationDisabled = true
    }

    private func endCriticalDictationActivity() {
        guard automaticTerminationDisabled else { return }
        ProcessInfo.processInfo.enableAutomaticTermination("ZFlow dictation in progress")
        automaticTerminationDisabled = false
    }

    private func beginRecording(triggerMode: RecordingTriggerMode) {
        os_log(.info, log: recordingLog, "beginRecording() entered")
        beginCriticalDictationActivity()
        clearPendingOverlayDismissToken()
        errorMessage = nil

        isRecording = true
        statusText = "Starting..."
        hasShownScreenshotPermissionAlert = false

        // Show initializing dots only if engine takes longer than 0.2s to start
        var overlayShown = false
        cancelRecordingInitializationTimer()
        let initTimer = DispatchSource.makeTimerSource(queue: .main)
        recordingInitializationTimer = initTimer
        initTimer.schedule(deadline: .now() + 0.2)
        initTimer.setEventHandler { [weak self] in
            guard let self, !overlayShown else { return }
            overlayShown = true
            os_log(.info, log: recordingLog, "engine slow — showing initializing overlay")
            self.clearPendingOverlayDismissToken()
            self.overlayManager.showInitializing(
                mode: self.activeRecordingTriggerMode ?? triggerMode,
                isCommandMode: self.currentSessionIntent.isCommandMode
            )
        }
        initTimer.resume()

        // Transition to waveform when first real audio arrives (any non-zero RMS)
        let deviceUID = selectedMicrophoneID
        audioRecorder.onRecordingReady = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.cancelRecordingInitializationTimer()
                os_log(.info, log: recordingLog, "first real audio — transitioning to waveform")
                self.statusText = "Recording..."
                self.clearPendingOverlayDismissToken()
                if overlayShown {
                    self.overlayManager.transitionToRecording(
                        mode: self.activeRecordingTriggerMode ?? triggerMode,
                        isCommandMode: self.currentSessionIntent.isCommandMode
                    )
                } else {
                    self.overlayManager.showRecording(
                        mode: self.activeRecordingTriggerMode ?? triggerMode,
                        isCommandMode: self.currentSessionIntent.isCommandMode
                    )
                }
                overlayShown = true
                self.playAlertSound(named: "Tink")
            }
        }
        audioRecorder.onRecordingFailure = { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.cancelRecordingInitializationTimer()
                self.handleRecordingFailure(error)
            }
        }

        startRealtimeStreamingIfEnabled()

        // Start engine on background thread so UI isn't blocked
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let t0 = CFAbsoluteTimeGetCurrent()
            do {
                try self.audioRecorder.startRecording(deviceUID: deviceUID)
                os_log(.info, log: recordingLog, "audioRecorder.startRecording() done: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
                DispatchQueue.main.async {
                    guard self.isRecording, self.activeRecordingTriggerMode != nil else { return }
                    self.startContextCapture()
                    self.audioLevelCancellable = self.audioRecorder.$audioLevel
                        .receive(on: DispatchQueue.main)
                        .sink { [weak self] level in
                            self?.overlayManager.updateAudioLevel(level)
                        }
                }
            } catch {
                DispatchQueue.main.async {
                    self.cancelRecordingInitializationTimer()
                    guard self.isRecording || self.activeRecordingTriggerMode != nil else { return }
                    self.handleRecordingFailure(error)
                }
            }
        }
    }

    private func handleRecordingFailure(_ error: Error) {
        cancelRecordingInitializationTimer()
        audioRecorder.onRecordingReady = nil
        audioRecorder.onRecordingFailure = nil
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil
        contextCaptureTask?.cancel()
        contextCaptureTask = nil
        capturedContext = nil
        tearDownRealtimeService()
        audioRecorder.cleanup()
        restoreAudioInterruptionIfNeeded()
        isRecording = false
        isTranscribing = false
        transcriptionTask?.cancel()
        transcriptionTask = nil
        if let transcribingAudioFileName {
            Self.deleteAudioFile(transcribingAudioFileName)
            self.transcribingAudioFileName = nil
        }
        activeRecordingTriggerMode = nil
        currentSessionIntent = .dictation
        shortcutSessionController.reset()
        endCriticalDictationActivity()
        errorMessage = formattedRecordingStartError(error)
        statusText = "Error"
        overlayManager.dismiss()
        refreshAvailableMicrophonesIfNeeded()
    }

    private func formattedRecordingStartError(_ error: Error) -> String {
        if let recorderError = error as? AudioRecorderError {
            return "Failed to start recording: \(recorderError.localizedDescription)"
        }

        let lower = error.localizedDescription.lowercased()
        if lower.contains("operation couldn't be completed") || lower.contains("operation could not be completed") {
            return "Failed to start recording: Audio input error. Verify microphone access is granted and a working mic is selected in System Settings > Sound > Input."
        }

        let nsError = error as NSError
        if nsError.domain == NSOSStatusErrorDomain {
            return "Failed to start recording (audio subsystem error \(nsError.code)). Check microphone permissions and selected input device."
        }

        return "Failed to start recording: \(error.localizedDescription)"
    }

    private func formattedTranscriptionError(_ error: Error) -> String {
        TranscriptionErrorPresentationCore.message(
            for: error,
            isOnline: NetworkMonitor.shared.isOnline
        )
    }

    func showMicrophonePermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Microphone Permission Required"
        alert.informativeText = "\(AppName.displayName) cannot record audio without Microphone access.\n\nGo to System Settings > Privacy & Security > Microphone and enable \(AppName.displayName)."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Dismiss")
        alert.icon = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openMicrophoneSettings()
        }
    }

    func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = Self.accessibilityAlertText(isAdHocSigned: Self.isAdHocSigned)
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Open System Settings")
        if Self.isAdHocSigned {
            alert.addButton(withTitle: "Reveal App in Finder")
        }
        alert.addButton(withTitle: "Dismiss")
        alert.icon = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openAccessibilitySettings()
        } else if Self.isAdHocSigned && response == .alertSecondButtonReturn {
            // Dragging the bundle onto the list is the reliable route for an
            // ad-hoc build, so hand the user the bundle.
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        }
    }

    /// True when this build carries no stable signing identity.
    ///
    /// macOS identifies such a build by the hash of its binary, which changes
    /// on every compile, so a granted permission stops applying as soon as the
    /// app is rebuilt and the system often will not re-prompt. Release builds
    /// are signed with a Developer ID and never hit this.
    static let isAdHocSigned: Bool = {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess,
              let code else { return false }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: 0), &information) == errSecSuccess,
              let info = information as? [String: Any] else { return false }
        // kSecCodeInfoFlags carries the adhoc bit (0x2).
        guard let flags = info[kSecCodeInfoFlags as String] as? UInt32 else { return false }
        return flags & 0x2 != 0
    }()

    /// The alert body. An ad-hoc build usually is not in the Accessibility list
    /// at all, so telling the user to switch it on there is a dead end.
    static func accessibilityAlertText(isAdHocSigned: Bool) -> String {
        let base = "\(AppName.displayName) cannot type transcriptions without Accessibility access."
        guard isAdHocSigned else {
            return base + "\n\nGo to System Settings > Privacy & Security > Accessibility and enable \(AppName.displayName)."
        }
        return base + """


This is an unsigned development build, so macOS identifies it by the hash of its binary. That hash changes every time the app is rebuilt, which is why a permission you already granted can stop working and why \(AppName.displayName) may not reappear in the list on its own.

In System Settings > Privacy & Security > Accessibility:
1. Remove any existing \(AppName.displayName) row with the − button.
2. Press + and pick the app (use Reveal App in Finder below to locate it).

To stop this recurring, sign development builds with a stable self-signed certificate instead.
"""
    }

    private func precomputeMacros() {
        precomputedMacros = voiceMacros.map { macro in
            PrecomputedMacro(
                original: macro,
                normalizedCommand: normalize(macro.command)
            )
        }
    }

    private func normalize(_ text: String) -> String {
        let lowercased = text.lowercased()
        let strippedPunctuation = lowercased.components(separatedBy: CharacterSet.punctuationCharacters).joined()
        return strippedPunctuation.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseTranscriptCommands(
        from transcript: String,
        pressEnterCommandEnabled: Bool
    ) -> TranscriptCommandParsingResult {
        guard pressEnterCommandEnabled else {
            return TranscriptCommandParsingResult(
                transcript: transcript.trimmingCharacters(in: .whitespacesAndNewlines),
                shouldPressEnterAfterPaste: false
            )
        }

        let fullRange = NSRange(transcript.startIndex..<transcript.endIndex, in: transcript)
        guard
            let match = trailingPressEnterCommandPattern.firstMatch(in: transcript, range: fullRange),
            let commandRange = Range(match.range, in: transcript)
        else {
            return TranscriptCommandParsingResult(
                transcript: transcript.trimmingCharacters(in: .whitespacesAndNewlines),
                shouldPressEnterAfterPaste: false
            )
        }

        var strippedTranscript = transcript
        strippedTranscript.removeSubrange(commandRange)

        return TranscriptCommandParsingResult(
            transcript: strippedTranscript.trimmingCharacters(in: .whitespacesAndNewlines),
            shouldPressEnterAfterPaste: true
        )
    }

    private static func statusMessage(
        for outcome: TranscriptProcessingOutcome,
        parsedTranscript: TranscriptCommandParsingResult,
        isRetry: Bool = false
    ) -> String {
        let status = outcome.statusMessage(isRetry: isRetry)
        guard parsedTranscript.shouldPressEnterAfterPaste else { return status }
        return "\(status); detected press enter command"
    }

    func playAlertSound(named name: String) {
        guard alertSoundsEnabled else { return }

        let sound = NSSound(named: name)
        sound?.volume = soundVolume
        sound?.play()
    }

    private func findMatchingMacro(for transcript: String) -> VoiceMacro? {
        let normalizedTranscript = normalize(transcript)
        guard !normalizedTranscript.isEmpty else { return nil }

        return precomputedMacros.first {
            normalizedTranscript == $0.normalizedCommand
        }?.original
    }

    private enum TranscriptProcessingOutcome {
        case skippedEmptyRawTranscript
        case voiceMacro(command: String)
        case postProcessingSucceeded
        case postProcessingFailedFallback
        case postProcessingDisabled
        case localPostProcessingFailed
        case preservedExactWording
        case preservedExactWordingTranslated
        case preservedExactWordingTranslationFailedFallback
        case commandModeSucceeded(invocation: CommandInvocation)
        case commandModeFailedFallback(invocation: CommandInvocation)

        func statusMessage(isRetry: Bool = false) -> String {
            switch self {
            case .skippedEmptyRawTranscript:
                return "Skipped macros and post-processing for empty raw transcript"
            case .voiceMacro(let command):
                return "Voice macro used: \(command)"
            case .postProcessingSucceeded:
                return isRetry ? "Post-processing succeeded (retried)" : "Post-processing succeeded"
            case .postProcessingFailedFallback:
                return isRetry
                    ? "Post-processing failed on retry, using raw transcript"
                    : "Post-processing failed, using raw transcript"
            case .postProcessingDisabled:
                return "Post-processing off, using raw transcript"
            case .localPostProcessingFailed:
                return "On-device cleanup failed, using raw transcript"
            case .preservedExactWording:
                return "Preserved exact wording, skipped post-processing"
            case .preservedExactWordingTranslated:
                return "Preserved exact wording, translated to output language"
            case .preservedExactWordingTranslationFailedFallback:
                return "Verbatim translation failed, using untranslated raw transcript"
            case .commandModeSucceeded(let invocation):
                return "Edit mode succeeded (\(invocation.rawValue))"
            case .commandModeFailedFallback(let invocation):
                return "Edit mode failed, using selected text (\(invocation.rawValue))"
            }
        }
    }

    private func processTranscript(
        _ rawTranscript: String,
        intent: SessionIntent,
        context: AppContext,
        postProcessingService: PostProcessingService,
        customVocabulary: String,
        customSystemPrompt: String,
        outputLanguage: String = "",
        preserveExactWording: Bool,
        postProcessingEnabled: Bool
    ) async -> (finalTranscript: String, outcome: TranscriptProcessingOutcome, prompt: String) {
        let trimmedRawTranscript = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedRawTranscript.isEmpty else {
            return ("", .skippedEmptyRawTranscript, "")
        }

        if case .command(let invocation, let selectedText) = intent {
            do {
                let result = try await postProcessingService.commandTransform(
                    selectedText: selectedText,
                    voiceCommand: rawTranscript,
                    context: context,
                    customVocabulary: customVocabulary,
                    outputLanguage: outputLanguage
                )
                return (result.transcript, .commandModeSucceeded(invocation: invocation), result.prompt)
            } catch {
                os_log(.error, log: recordingLog, "Edit mode failed: %{public}@", error.localizedDescription)
                return (selectedText, .commandModeFailedFallback(invocation: invocation), "")
            }
        }

        if let macro = findMatchingMacro(for: trimmedRawTranscript) {
            os_log(.info, log: recordingLog, "Voice macro triggered: %{public}@", macro.command)
            return (macro.payload, .voiceMacro(command: macro.command), "")
        }

        // Post-processing turned off entirely: paste what the speech-to-text
        // model returned, with no second network call. Unlike preserve-exact-
        // wording this also skips translation, because the point of the switch
        // is that nothing rewrites the transcript. Edit Mode and voice macros
        // are deliberate invocations and still run — they are handled above.
        //
        // Learned spellings are still applied: they are the user's own
        // corrections, not a rewrite by a model.
        if !postProcessingEnabled {
            return (applyLearnedCorrections(trimmedRawTranscript), .postProcessingDisabled, "")
        }

        // Preserve-exact-wording mode. Two sub-cases so translation
        // stays honored:
        //
        //   1. No Output Language set — skip the LLM entirely and
        //      return the raw transcript verbatim.
        //   2. Output Language IS set — route through a stripped-down
        //      translate-only prompt. The user asked for another
        //      language; silently dropping translation defeats their
        //      settings. The translate-only path preserves filler,
        //      informal wording, and profanity 1:1 while still hitting
        //      the target language.
        if preserveExactWording {
            let targetLanguage = outputLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
            if targetLanguage.isEmpty {
                return (applyLearnedCorrections(trimmedRawTranscript), .preservedExactWording, "")
            }
            do {
                let result = try await postProcessingService.translateVerbatim(
                    transcript: trimmedRawTranscript,
                    targetLanguage: targetLanguage
                )
                return (result.transcript, .preservedExactWordingTranslated, result.prompt)
            } catch {
                os_log(.error, log: recordingLog,
                       "Verbatim translation failed: %{public}@",
                       error.localizedDescription)
                return (trimmedRawTranscript, .preservedExactWordingTranslationFailedFallback, "")
            }
        }

        if postProcessingEngine == .local, #available(macOS 26.0, *) {
            do {
                let result = try await LocalTextProcessor.postProcess(
                    transcript: trimmedRawTranscript,
                    contextSummary: context.contextSummary,
                    customVocabulary: customVocabulary,
                    customSystemPrompt: customSystemPrompt,
                    outputLanguage: outputLanguage
                )
                return (applyLearnedCorrections(result.transcript), .postProcessingSucceeded, result.prompt)
            } catch {
                // The raw transcript is kept rather than sent to the provider:
                // on-device cleanup is chosen so the text stays on the Mac, and
                // a silent upload on failure would defeat that.
                os_log(
                    .error,
                    log: recordingLog,
                    "On-device post-processing failed: %{public}@",
                    error.localizedDescription
                )
                return (applyLearnedCorrections(trimmedRawTranscript), .localPostProcessingFailed, "")
            }
        }

        do {
            let result = try await postProcessingService.postProcess(
                transcript: trimmedRawTranscript,
                context: context,
                customVocabulary: customVocabulary,
                customSystemPrompt: customSystemPrompt,
                outputLanguage: outputLanguage
            )
            return (applyLearnedCorrections(result.transcript), .postProcessingSucceeded, result.prompt)
        } catch {
            os_log(.error, log: recordingLog, "Post-processing failed: %{public}@", error.localizedDescription)
            return (applyLearnedCorrections(trimmedRawTranscript), .postProcessingFailedFallback, "")
        }
    }

    /// Await the realtime WebSocket's final transcript. If it errors out (or
    /// was never started) fall back to the file-based POST so the user still
    /// gets a transcript. Runs the realtime commit and file upload in that
    /// strict order to avoid paying for both when realtime succeeds.
    private static func resolveRawTranscript(
        realtimeService: (any StreamingTranscriptionSession)?,
        fileService: TranscriptionService,
        fileURL: URL,
        allowsCloudFallback: Bool
    ) async throws -> String {
        if let realtimeService {
            do {
                try Task.checkCancellation()
                return try await withTaskCancellationHandler {
                    try await realtimeService.commitAndAwaitFinal()
                } onCancel: {
                    realtimeService.cancel()
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                // On-device transcription is chosen precisely so audio does not
                // leave the machine. Quietly uploading the recording after a
                // local failure would break that promise, so the local error is
                // surfaced instead.
                guard allowsCloudFallback else { throw error }
                return try await fileService.transcribe(fileURL: fileURL)
            }
        }
        return try await fileService.transcribe(fileURL: fileURL)
    }

    private func stopAndTranscribe() {
        cancelPendingShortcutStart()
        cancelRecordingInitializationTimer()
        shortcutSessionController.reset()
        activeRecordingTriggerMode = nil
        let sessionIntent = currentSessionIntent
        currentSessionIntent = .dictation
        audioRecorder.onRecordingReady = nil
        audioRecorder.onRecordingFailure = nil
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil
        debugStatusMessage = "Preparing audio"
        let sessionContext = capturedContext
        let inFlightContextTask = contextCaptureTask
        capturedContext = nil
        contextCaptureTask = nil
        lastRawTranscript = ""
        lastPostProcessedTranscript = ""
        lastContextSummary = ""
        lastPostProcessingStatus = ""
        lastPostProcessingPrompt = ""
        lastContextScreenshotDataURL = nil
        lastContextScreenshotStatus = "No screenshot"
        isRecording = false
        restoreAudioInterruptionIfNeeded()
        isTranscribing = true
        statusText = "Preparing audio..."
        errorMessage = nil
        overlayManager.showTranscribing()
        audioRecorder.stopRecording { [weak self] fileURL in
            guard let self else { return }
            guard let fileURL else {
                self.isTranscribing = false
                self.audioRecorder.cleanup()
                self.endCriticalDictationActivity()
                self.errorMessage = "No audio recorded"
                self.statusText = "Error"
                self.overlayManager.dismiss()
                self.refreshAvailableMicrophonesIfNeeded()
                return
            }

            guard self.isTranscribing else {
                self.tearDownRealtimeService()
                self.audioRecorder.cleanup()
                self.refreshAvailableMicrophonesIfNeeded()
                return
            }

            let savedAudioFile = Self.saveAudioFile(from: fileURL)
            let transcriptionFileURL = savedAudioFile?.fileURL ?? fileURL
            self.transcribingAudioFileName = savedAudioFile?.fileName
            self.statusText = "Transcribing..."
            self.debugStatusMessage = "Transcribing audio"

        let postProcessingService = PostProcessingService(
            apiKey: apiKey,
            baseURL: apiBaseURL,
            preferredModel: postProcessingModel,
            preferredFallbackModel: postProcessingFallbackModel,
            instructionExecutionGuardEnabled: instructionExecutionGuardEnabled
        )

            let activeRealtime = self.realtimeService
            self.realtimeService = nil
            self.audioRecorder.onPCM16Samples = nil
            self.transcriptionTask?.cancel()
            guard self.isTranscribing else {
                if let savedAudioFile {
                    Self.deleteAudioFile(savedAudioFile.fileName)
                }
                self.transcribingAudioFileName = nil
                activeRealtime?.cancel()
                self.audioRecorder.cleanup()
                self.endCriticalDictationActivity()
                self.refreshAvailableMicrophonesIfNeeded()
                return
            }
            self.transcriptionTask = Task {
                defer {
                    activeRealtime?.cancel()
                }
                do {
                    let transcriptionService = try self.makeTranscriptionService()
                    async let transcript = Self.resolveRawTranscript(
                        realtimeService: activeRealtime,
                        fileService: transcriptionService,
                        fileURL: transcriptionFileURL,
                        allowsCloudFallback: self.transcriptionEngine != .local
                    )
                    let rawTranscript = try await transcript
                    let parsedTranscript = Self.parseTranscriptCommands(
                        from: rawTranscript,
                        pressEnterCommandEnabled: self.isPressEnterVoiceCommandEnabled
                    )
                    try Task.checkCancellation()
                    // Capture the parsed raw transcript as lastTranscript before
                    // post-processing runs. If anything after this throws or focus
                    // shifts mid-paste, the Paste Again shortcut still has the raw
                    // text instead of the previous dictation's stale value.
                    let bootstrapTranscript = parsedTranscript.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !bootstrapTranscript.isEmpty {
                        await MainActor.run { [weak self] in
                            self?.lastTranscript = bootstrapTranscript
                        }
                    }
                    let appContext: AppContext
                    if let sessionContext {
                        appContext = sessionContext
                    } else if let inFlightContext = await inFlightContextTask?.value {
                        appContext = inFlightContext
                    } else {
                        appContext = self.fallbackContextAtStop()
                    }
                    try Task.checkCancellation()
                    await MainActor.run { [weak self] in
                        self?.debugStatusMessage = "Running post-processing"
                    }
                    let result = await self.processTranscript(
                        parsedTranscript.transcript,
                        intent: sessionIntent,
                        context: appContext,
                        postProcessingService: postProcessingService,
                        customVocabulary: self.vocabularyIncludingLearnedSpellings,
                        customSystemPrompt: self.customSystemPrompt,
                        outputLanguage: self.outputLanguage,
                        preserveExactWording: self.preserveExactWording,
                        postProcessingEnabled: self.postProcessingEnabled
                    )
                    try Task.checkCancellation()

                    await MainActor.run {
                        guard self.isTranscribing else { return }
                        self.lastContextSummary = appContext.contextSummary
                        self.lastContextScreenshotDataURL = appContext.screenshotDataURL
                        self.lastContextScreenshotStatus = self.screenshotStatusText(for: appContext)
                        self.lastContextAppName = appContext.appName ?? ""
                        self.lastContextBundleIdentifier = appContext.bundleIdentifier ?? ""
                        self.lastContextWindowTitle = appContext.windowTitle ?? ""
                        self.lastContextSelectedText = appContext.selectedText ?? ""
                        self.lastContextLLMPrompt = appContext.contextPrompt ?? ""
                        let trimmedRawTranscript = parsedTranscript.transcript
                        let trimmedFinalTranscript = result.finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                        let processingStatus = Self.statusMessage(
                            for: result.outcome,
                            parsedTranscript: parsedTranscript
                        )
                        self.lastPostProcessingPrompt = result.prompt
                        self.lastRawTranscript = trimmedRawTranscript
                        self.lastPostProcessedTranscript = trimmedFinalTranscript
                        self.lastPostProcessingStatus = processingStatus
                        self.recordPipelineHistoryEntry(
                            rawTranscript: trimmedRawTranscript,
                            postProcessedTranscript: trimmedFinalTranscript,
                            postProcessingPrompt: result.prompt,
                            systemPrompt: Self.resolvedSystemPrompt(self.customSystemPrompt),
                            context: appContext,
                            processingStatus: processingStatus,
                            intent: sessionIntent,
                            audioFileName: savedAudioFile?.fileName
                        )
                        self.transcriptionTask = nil
                        self.transcribingAudioFileName = nil
                        self.lastTranscript = trimmedFinalTranscript
                        self.isTranscribing = false
                        self.endCriticalDictationActivity()
                        self.debugStatusMessage = "Done"
                        let completionStatusText = self.preserveClipboard ? "Pasted at cursor!" : "Copied to clipboard!"
                        let enterOnlyStatusText = "Pressed Enter"
                        let shouldPressEnterAfterPaste = parsedTranscript.shouldPressEnterAfterPaste

                        let shouldPersistRawDictationFallback: Bool
                        switch result.outcome {
                        case .postProcessingFailedFallback,
                             .preservedExactWordingTranslationFailedFallback:
                            shouldPersistRawDictationFallback = !trimmedFinalTranscript.isEmpty
                        default:
                            shouldPersistRawDictationFallback = false
                        }

                        if trimmedFinalTranscript.isEmpty {
                            self.statusText = shouldPressEnterAfterPaste ? enterOnlyStatusText : "Nothing to transcribe"
                            self.clearPendingOverlayDismissToken()
                            if !self.showPostTranscriptionUpdateReminderIfNeeded() {
                                self.overlayManager.dismiss()
                            }
                            if shouldPressEnterAfterPaste {
                                self.pressEnterWhenShortcutReleased()
                            }
                        } else {
                            self.statusText = completionStatusText
                            if shouldPersistRawDictationFallback {
                                self.scheduleOverlayDismissAfterFailureIndicator(after: 2.5)
                            } else {
                                self.clearPendingOverlayDismissToken()
                                if !self.showPostTranscriptionUpdateReminderIfNeeded() {
                                    self.overlayManager.dismiss()
                                }
                            }

                            let pendingClipboardRestore = self.writeTranscriptToPasteboard(trimmedFinalTranscript)
                            // Watch the field for hand corrections to this
                            // text, which is how new dictionary words are
                            // learned.
                            self.beginWatchingForCorrections(of: trimmedFinalTranscript)
                            self.pasteAtCursorWhenShortcutReleased {
                                if shouldPressEnterAfterPaste {
                                    self.pressEnterAfterPaste {
                                        self.restoreClipboardIfNeeded(pendingClipboardRestore)
                                    }
                                } else {
                                    self.restoreClipboardIfNeeded(pendingClipboardRestore)
                                }
                            }
                        }

                        self.audioRecorder.cleanup()
                        self.refreshAvailableMicrophonesIfNeeded()

                        self.scheduleReadyStatusReset(after: 3, matching: [completionStatusText, "Nothing to transcribe", enterOnlyStatusText])
                    }
                } catch is CancellationError {
                    await MainActor.run {
                        self.transcriptionTask = nil
                        self.endCriticalDictationActivity()
                    }
                } catch {
                    let resolvedContext: AppContext
                    if let sessionContext {
                        resolvedContext = sessionContext
                    } else if let inFlightContext = await inFlightContextTask?.value {
                        resolvedContext = inFlightContext
                    } else {
                        resolvedContext = self.fallbackContextAtStop()
                    }
                    await MainActor.run {
                        guard self.isTranscribing else { return }
                        self.transcriptionTask = nil
                        self.transcribingAudioFileName = nil
                        let userFacingErrorMessage = self.formattedTranscriptionError(error)
                        self.errorMessage = userFacingErrorMessage
                        self.isTranscribing = false
                        self.endCriticalDictationActivity()
                        self.statusText = "Error"
                        self.lastPostProcessedTranscript = ""
                        self.lastRawTranscript = ""
                        self.lastContextSummary = ""
                        self.lastPostProcessingStatus = "Error: \(error.localizedDescription)"
                        self.lastPostProcessingPrompt = ""
                        self.lastContextScreenshotDataURL = resolvedContext.screenshotDataURL
                        self.lastContextScreenshotStatus = self.screenshotStatusText(for: resolvedContext)
                        // Recorded before the toast so the toast's Retry button
                        // has a history entry — and its saved audio — to re-run.
                        let failedEntry = self.recordPipelineHistoryEntry(
                            rawTranscript: "",
                            postProcessedTranscript: "",
                            postProcessingPrompt: "",
                            systemPrompt: Self.resolvedSystemPrompt(self.customSystemPrompt),
                            context: resolvedContext,
                            processingStatus: "Error: \(error.localizedDescription)",
                            intent: sessionIntent,
                            audioFileName: savedAudioFile?.fileName
                        )
                        // Retry replays the recording rather than asking the
                        // user to say it again, so it is only offered when the
                        // audio was actually kept.
                        let canRetry = savedAudioFile != nil
                            && Self.audioFileExists(named: failedEntry.audioFileName)
                        self.overlayManager.showError(
                            userFacingErrorMessage,
                            retry: canRetry ? { [weak self] in
                                self?.retryTranscription(item: failedEntry, presentsLiveFeedback: true)
                            } : nil
                        )
                        self.audioRecorder.cleanup()
                        self.refreshAvailableMicrophonesIfNeeded()
                    }
                }
            }
        }
    }

    static func resolvedSystemPrompt(_ customSystemPrompt: String) -> String {
        customSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? PostProcessingService.defaultSystemPrompt
            : customSystemPrompt
    }

    @discardableResult
    private func recordPipelineHistoryEntry(
        rawTranscript: String,
        postProcessedTranscript: String,
        postProcessingPrompt: String,
        systemPrompt: String,
        context: AppContext,
        processingStatus: String,
        intent: SessionIntent,
        audioFileName: String? = nil
    ) -> PipelineHistoryItem {
        let newEntry = PipelineHistoryItem(
            intent: intent.persistedIntent,
            selectedText: intent.persistedSelectedText,
            capturedSelection: context.selectedText,
            timestamp: Date(),
            rawTranscript: rawTranscript,
            postProcessedTranscript: postProcessedTranscript,
            postProcessingPrompt: postProcessingPrompt,
            systemPrompt: systemPrompt,
            contextSummary: context.contextSummary,
            contextSystemPrompt: context.contextSystemPrompt,
            contextPrompt: context.contextPrompt,
            contextScreenshotDataURL: context.screenshotDataURL,
            contextScreenshotStatus: screenshotStatusText(for: context),
            postProcessingStatus: processingStatus,
            debugStatus: debugStatusMessage,
            customVocabulary: customVocabulary,
            audioFileName: audioFileName,
            contextAppName: context.appName,
            contextBundleIdentifier: context.bundleIdentifier,
            contextWindowTitle: context.windowTitle
        )
        // Aggregate counts only — how many words, how long, which app. The
        // text itself is already in the history above; none of it is repeated
        // here, and none of it leaves the machine.
        let spokenFor = dictationStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let finalText = postProcessedTranscript.isEmpty ? rawTranscript : postProcessedTranscript
        let appName = context.appName
        let corrections = lastRunCorrectionsApplied
        let onDevice = transcriptionEngine == .local
        dictationStartedAt = nil
        lastRunCorrectionsApplied = 0
        UsageStatisticsStore.shared.update { stats in
            UsageStatisticsCore.recording(
                stats,
                transcript: finalText,
                speakingSeconds: spokenFor,
                appName: appName,
                correctionsApplied: corrections,
                onDevice: onDevice,
                at: newEntry.timestamp
            )
        }

        do {
            let removedAudioFileNames = try pipelineHistoryStore.append(newEntry, maxCount: maxPipelineHistoryCount)
            for audioFileName in removedAudioFileNames {
                Self.deleteAudioFile(audioFileName)
            }
            pipelineHistory = pipelineHistoryStore.loadAllHistory()
        } catch {
            errorMessage = "Unable to save run history entry: \(error.localizedDescription)"
        }
        return newEntry
    }

    /// True when this Mac can transcribe on-device. Drives both the engine
    /// picker and the fall back to the cloud when the setting says local but
    /// the machine cannot do it.
    /// Why on-device cleanup cannot run, or nil when it can. Drives the picker
    /// and the warning beside it.
    static var localPostProcessingUnavailability: String? {
        guard #available(macOS 26.0, *) else {
            return "On-device cleanup needs macOS 26 or later."
        }
        return LocalTextProcessor.unavailability?.message
    }

    static var isLocalTranscriptionSupported: Bool {
        guard #available(macOS 26.0, *) else { return false }
        return LocalSpeechTranscriber.isSupported
    }

    private func startLocalTranscriptionIfSelected() -> Bool {
        guard transcriptionEngine == .local, Self.isLocalTranscriptionSupported else { return false }
        guard #available(macOS 26.0, *) else { return false }

        // Resolving the locale is async, but recording must not wait on it, so
        // the session buffers audio until its analyzer is up.
        let languageCode = resolvedTranscriptionLanguage
        let sampleRate = audioRecorder.pcm16SampleRate
        let session = LocalSpeechTranscriber(
            languageCode: languageCode,
            inputSampleRate: sampleRate
        )
        do {
            try session.start()
        } catch {
            os_log(
                .error,
                log: recordingLog,
                "failed to start on-device transcription: %{public}@",
                error.localizedDescription
            )
            return false
        }
        realtimeService = session
        audioRecorder.onPCM16Samples = { [weak session] data in
            session?.appendPCM16(data)
        }
        return true
    }

    /// Starting a dictation ends any watch on the previous one.
    ///
    /// The watcher reads another app's Accessibility tree, which is slow work
    /// competing for attention exactly when the user wants recording to begin.
    /// A correction made more than one dictation ago is not worth that.
    private func stopWatchingForCorrections() {
        correctionWatcher.stop()
    }

    private func startRealtimeStreamingIfEnabled() {
        if startLocalTranscriptionIfSelected() { return }
        guard realtimeStreamingEnabled else { return }
        let trimmedBase = resolvedTranscriptionBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBase.isEmpty else {
            os_log(.info, log: recordingLog, "realtime streaming requested but base URL is empty — skipping")
            return
        }
        let model = realtimeStreamingModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let config = RealtimeTranscriptionService.Configuration(
            baseURL: trimmedBase,
            apiKey: resolvedTranscriptionAPIKey,
            model: model,
            language: resolvedTranscriptionLanguage
        )
        let service = RealtimeTranscriptionService(config: config)
        do {
            try service.start()
        } catch {
            os_log(.error, log: recordingLog, "failed to start realtime service: %{public}@", error.localizedDescription)
            return
        }
        realtimeService = service
        audioRecorder.onPCM16Samples = { [weak service] data in
            service?.appendPCM16(data)
        }
    }

    private func tearDownRealtimeService() {
        audioRecorder.onPCM16Samples = nil
        realtimeService?.cancel()
        realtimeService = nil
    }

    private func startContextCapture() {
        contextCaptureTask?.cancel()
        capturedContext = nil
        lastContextSummary = contextInferenceEnabled
            ? "Collecting app context..."
            : "Context inference disabled in Settings"
        lastPostProcessingStatus = ""
        lastContextScreenshotDataURL = nil
        lastContextScreenshotStatus = contextScreenshotEnabled && contextInferenceEnabled
            ? "Collecting screenshot..."
            : "Disabled in Settings"

        contextCaptureTask = Task { [weak self] in
            guard let self else { return nil }
            let context = await self.contextService.collectContext()
            await MainActor.run {
                self.capturedContext = context
                self.lastContextSummary = context.contextSummary
                self.lastContextScreenshotDataURL = context.screenshotDataURL
                self.lastContextScreenshotStatus = self.screenshotStatusText(for: context)
                self.lastContextAppName = context.appName ?? ""
                self.lastContextBundleIdentifier = context.bundleIdentifier ?? ""
                self.lastContextWindowTitle = context.windowTitle ?? ""
                self.lastContextSelectedText = context.selectedText ?? ""
                self.lastContextLLMPrompt = context.contextPrompt ?? ""
                self.lastPostProcessingStatus = "App context captured"
                self.handleScreenshotCaptureIssue(context.screenshotError)
            }
            return context
        }
    }

    private func fallbackContextAtStop() -> AppContext {
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let windowTitle = focusedWindowTitle(for: frontmostApp)
        return AppContext(
            appName: frontmostApp?.localizedName,
            bundleIdentifier: frontmostApp?.bundleIdentifier,
            windowTitle: windowTitle,
            selectedText: nil,
            currentActivity: "Could not refresh app context at stop time; using text-only post-processing.",
            contextSystemPrompt: resolvedContextSystemPrompt(),
            contextPrompt: nil,
            screenshotDataURL: nil,
            screenshotMimeType: nil,
            screenshotError: "No app context captured before stop"
        )
    }

    private func resolvedContextSystemPrompt() -> String {
        let trimmedPrompt = customContextPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedPrompt.isEmpty ? AppContextService.defaultContextPrompt : trimmedPrompt
    }

    private func focusedWindowTitle(for app: NSRunningApplication?) -> String? {
        guard let app else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        return focusedWindowTitle(from: appElement)
    }

    private func focusedWindowTitle(from appElement: AXUIElement) -> String? {
        guard let focusedWindow = accessibilityElement(from: appElement, attribute: kAXFocusedWindowAttribute as CFString) else {
            return nil
        }

        guard let windowTitle = accessibilityString(from: focusedWindow, attribute: kAXTitleAttribute as CFString) else {
            return nil
        }

        return trimmedText(windowTitle)
    }

    private func accessibilityElement(from element: AXUIElement, attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success,
              let rawValue = value,
              CFGetTypeID(rawValue) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(rawValue, to: AXUIElement.self)
    }

    private func accessibilityString(from element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let stringValue = value as? String else { return nil }
        return stringValue
    }

    private func trimmedText(_ value: String) -> String? {
        let trimmed = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        return trimmed.isEmpty ? nil : trimmed
    }

    /// One-line screenshot state for the debug panel and pipeline history.
    /// Distinguishes "the user turned capture off" from a capture that was
    /// attempted and failed, so a deliberately text-only run does not read as
    /// a broken one.
    private func screenshotStatusText(for context: AppContext) -> String {
        guard contextScreenshotEnabled, contextInferenceEnabled else { return "Disabled in Settings" }
        if let error = context.screenshotError, !error.isEmpty { return error }
        guard context.screenshotDataURL != nil else { return "No screenshot" }
        return "available (\(context.screenshotMimeType ?? "image"))"
    }

    private func handleScreenshotCaptureIssue(_ message: String?) {
        guard let message, !message.isEmpty else {
            hasShownScreenshotPermissionAlert = false
            return
        }

        os_log(.error, "Screenshot capture issue: %{public}@", message)

        if isScreenCapturePermissionError(message) && !hasShownScreenshotPermissionAlert {
            hasScreenRecordingPermission = false
            guard currentSessionIntent.isCommandMode else { return }
            errorMessage = message
            hasShownScreenshotPermissionAlert = true

            // Permission errors are fatal — stop recording
            tearDownRealtimeService()
            audioRecorder.cancelRecording()
            audioLevelCancellable?.cancel()
            audioLevelCancellable = nil
            contextCaptureTask?.cancel()
            contextCaptureTask = nil
            capturedContext = nil
            isRecording = false
            restoreAudioInterruptionIfNeeded()
            shortcutSessionController.reset()
            activeRecordingTriggerMode = nil
            endCriticalDictationActivity()
            statusText = "Screenshot Required"
            overlayManager.dismiss()

            playAlertSound(named: "Basso")
            showScreenshotPermissionAlert(message: message)
        }
        // Non-permission errors (transient failures) — continue recording without context
    }

    private func isScreenCapturePermissionError(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("screen recording permission not granted")
            || lowered.contains("requires screen recording permission")
    }

    private func showScreenshotPermissionAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Required"
        alert.informativeText = "\(message)\n\n\(AppName.displayName) requires Screen Recording permission to capture screenshots for context-aware transcription.\n\nGo to System Settings > Privacy & Security > Screen Recording and enable \(AppName.displayName)."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Dismiss")
        alert.icon = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openScreenCaptureSettings()
        }
    }

    private func showScreenshotCaptureErrorAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "Screenshot Capture Failed"
        alert.informativeText = "\(message)\n\nA screenshot is required for context-aware transcription. Recording has been stopped."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Dismiss")
        alert.icon = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)
        _ = alert.runModal()
    }

    func toggleDebugOverlay() {
        if isDebugOverlayActive {
            stopDebugOverlay()
        } else {
            startDebugOverlay()
        }
    }

    private func startDebugOverlay() {
        isDebugOverlayActive = true
        clearPendingOverlayDismissToken()
        overlayManager.showRecording()

        // Simulate audio levels with a timer
        var phase: Double = 0.0
        debugOverlayTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            phase += 0.15
            // Generate a fake audio level that oscillates like speech
            let base = 0.3 + 0.2 * sin(phase)
            let noise = Float.random(in: -0.15...0.15)
            let level = min(max(Float(base) + noise, 0.0), 1.0)
            self.overlayManager.updateAudioLevel(level)
        }
    }

    private func stopDebugOverlay() {
        debugOverlayTimer?.invalidate()
        debugOverlayTimer = nil
        isDebugOverlayActive = false
        clearPendingOverlayDismissToken()
        overlayManager.dismiss()
    }

    private func clearPendingOverlayDismissToken() {
        pendingOverlayDismissToken = nil
    }

    @MainActor
    private func showPostTranscriptionUpdateReminderIfNeeded() -> Bool {
        if debugShowsUpdateReminderAfterDictation {
            showDebugUpdateAvailableOverlay()
            return true
        }

        let updateManager = UpdateManager.shared
        guard updateManager.shouldShowPostTranscriptionReminder() else { return false }

        let dismissToken = UUID()
        pendingOverlayDismissToken = dismissToken
        updateManager.markPostTranscriptionReminderShown()
        overlayManager.showUpdateAvailable(version: updateManager.latestReleaseVersion)

        DispatchQueue.main.asyncAfter(deadline: .now() + postTranscriptionUpdateReminderDuration) { [weak self] in
            guard let self, self.pendingOverlayDismissToken == dismissToken else { return }
            self.pendingOverlayDismissToken = nil
            self.overlayManager.dismiss()
        }

        return true
    }

    @MainActor
    func showDebugUpdateAvailableOverlay() {
        let updateManager = UpdateManager.shared
        let version = updateManager.latestReleaseVersion.isEmpty ? "9.9.9" : updateManager.latestReleaseVersion
        let dismissToken = UUID()
        if isDebugOverlayActive || debugOverlayTimer != nil {
            stopDebugOverlay()
        }
        pendingOverlayDismissToken = dismissToken
        overlayManager.showUpdateAvailable(version: version)

        DispatchQueue.main.asyncAfter(deadline: .now() + postTranscriptionUpdateReminderDuration) { [weak self] in
            guard let self, self.pendingOverlayDismissToken == dismissToken else { return }
            self.pendingOverlayDismissToken = nil
            self.overlayManager.dismiss()
        }
    }

    @MainActor
    private func handleUpdateOverlayPressed() {
        clearPendingOverlayDismissToken()
        overlayManager.dismiss()
        selectedSettingsTab = .general
        NotificationCenter.default.post(name: .showSettings, object: nil)

        DispatchQueue.main.async {
            if UpdateManager.shared.updateAvailable {
                UpdateManager.shared.showUpdateAlert()
            }
        }
    }

    private func scheduleOverlayDismissAfterFailureIndicator(after delay: TimeInterval) {
        let dismissToken = UUID()
        pendingOverlayDismissToken = dismissToken
        overlayManager.showFailureIndicator()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.pendingOverlayDismissToken == dismissToken else { return }
            self.pendingOverlayDismissToken = nil
            self.overlayManager.dismiss()
        }
    }

    func toggleDebugPanel() {
        selectedSettingsTab = .history
        NotificationCenter.default.post(name: .showSettings, object: nil)
    }

    private func pasteAtCursor() {
        let source = CGEventSource(stateID: .hidSystemState)
        let vKeyCode = keyCodeForCharacter("v") ?? 9

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cgSessionEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cgSessionEventTap)
    }

    private func keyCodeForCharacter(_ character: String) -> CGKeyCode? {
        guard let char = character.lowercased().utf16.first else { return nil }
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let layoutDataRef = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layoutData = unsafeBitCast(layoutDataRef, to: CFData.self) as Data
        return layoutData.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> CGKeyCode? in
            guard let layout = ptr.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return nil
            }
            for keyCode in UInt16(0)..<UInt16(128) {
                var chars = [UniChar](repeating: 0, count: 4)
                var charCount = 0
                var deadKeyState: UInt32 = 0
                let status = UCKeyTranslate(
                    layout, keyCode, UInt16(kUCKeyActionDisplay), 0,
                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState, 4, &charCount, &chars
                )
                if status == noErr, charCount > 0, chars[0] == char {
                    return CGKeyCode(keyCode)
                }
            }
            return nil
        }
    }

    private func pressEnter() {
        let source = CGEventSource(stateID: .hidSystemState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true)
        keyDown?.post(tap: .cgSessionEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)
        keyUp?.post(tap: .cgSessionEventTap)
    }

    /// Writes the final transcript to the system pasteboard.
    /// Also handles appending necessary trailing spaces, declaring transient
    /// types for clipboard managers, and saving the clipboard state for later restoration.
    /// - Parameter transcript: The text to be pasted.
    /// - Returns: A `PendingClipboardRestore` object if clipboard preservation is enabled, otherwise nil.
    private func writeTranscriptToPasteboard(_ transcript: String) -> PendingClipboardRestore? {
        let pasteboard = NSPasteboard.general
        let snapshot = preserveClipboard ? PreservedPasteboardSnapshot(pasteboard: pasteboard) : nil

        // Append a space when ending with sentence-ending punctuation so the
        // next dictation does not jam against the prior period.
        let textToWrite: String
        if let last = transcript.last, ".!?".contains(last) {
            textToWrite = transcript + " "
        } else {
            textToWrite = transcript
        }

        if keepDictationInClipboardHistory {
            // Plain write so clipboard managers record the dictation in history.
            pasteboard.clearContents()
            pasteboard.setString(textToWrite, forType: .string)
        } else {
            // Declare standard transient types alongside .string so well-behaved
            // clipboard managers (Maccy, Raycast, Paste, Clipy, Flycut, etc.) skip
            // recording this entry in their history. The text still pastes normally
            // via Cmd-V — only clipboard history is affected.
            //
            // See: https://github.com/nicke5012/TransientPasteboardType
            let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
            let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
            let autoGeneratedType = NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")
            let legacyTransientType = NSPasteboard.PasteboardType("de.petermaurer.TransientPasteboardType")

            pasteboard.declareTypes([
                .string,
                transientType,
                concealedType,
                autoGeneratedType,
                legacyTransientType
            ], owner: nil)

            pasteboard.setString(textToWrite, forType: .string)

            // Populate empty values for the marker types — some clipboard managers
            // check the data presence rather than just the declared type.
            pasteboard.setString("", forType: transientType)
            pasteboard.setString("", forType: concealedType)
            pasteboard.setString("", forType: autoGeneratedType)
            pasteboard.setString("", forType: legacyTransientType)
        }

        guard let snapshot else { return nil }
        return PendingClipboardRestore(
            snapshot: snapshot,
            expectedChangeCount: pasteboard.changeCount,
            writtenTranscript: textToWrite
        )
    }

    private func restoreClipboardIfNeeded(_ pendingRestore: PendingClipboardRestore?) {
        guard let pendingRestore else { return }

        // Some apps consume Cmd-V asynchronously, so restoring too quickly can paste
        // the pre-dictation clipboard instead of the transcript.
        DispatchQueue.main.asyncAfter(deadline: .now() + clipboardRestoreDelay) {
            let pasteboard = NSPasteboard.general
            // A bare changeCount check is too strict: browsers, iCloud Universal
            // Clipboard sync, and other background apps bump the change count
            // without the user copying anything, which left the transcript
            // stranded on the clipboard. Restore when nothing changed, or when the
            // clipboard still holds exactly the transcript we wrote (so the user
            // has not deliberately copied something new that we would clobber).
            let clipboardStillHoldsTranscript =
                pasteboard.string(forType: .string) == pendingRestore.writtenTranscript
            guard pasteboard.changeCount == pendingRestore.expectedChangeCount
                || clipboardStillHoldsTranscript else { return }
            pendingRestore.snapshot.restore(to: pasteboard)
        }
    }

    private func performAfterShortcutReleased(attempt: Int = 0, action: @escaping () -> Void) {
        let maxAttempts = 24
        if hotkeyManager.hasPressedShortcutInputs && attempt < maxAttempts {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
                self?.performAfterShortcutReleased(attempt: attempt + 1, action: action)
            }
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + pasteAfterShortcutReleaseDelay) {
            action()
        }
    }

    private func pasteAtCursorWhenShortcutReleased(completion: (() -> Void)? = nil) {
        performAfterShortcutReleased { [weak self] in
            self?.pasteAtCursor()
            completion?()
        }
    }

    private func pressEnterWhenShortcutReleased(completion: (() -> Void)? = nil) {
        performAfterShortcutReleased { [weak self] in
            self?.pressEnter()
            completion?()
        }
    }

    private func pressEnterAfterPaste(completion: (() -> Void)? = nil) {
        DispatchQueue.main.asyncAfter(deadline: .now() + pressEnterAfterPasteDelay) { [weak self] in
            self?.pressEnter()
            completion?()
        }
    }

    private func cancelRecordingInitializationTimer() {
        recordingInitializationTimer?.cancel()
        recordingInitializationTimer = nil
    }

    private func scheduleReadyStatusReset(after delay: TimeInterval, matching statuses: Set<String>? = nil) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            if let statuses, !statuses.contains(self.statusText) {
                return
            }
            self.statusText = "Ready"
        }
    }
}
