/**
 * ZFlow's settings, described once, in the shape the UI renders.
 *
 * The point of this file is that the new front end shows *our* settings — the
 * ones AppState actually reads — arranged the way the reference arranges its
 * own. Keys match AppState's storage keys exactly.
 */

type RowBase =
  | { kind: "toggle"; key: string; title: string; desc?: string; defaultValue: boolean; invert?: boolean }
  | { kind: "select"; key: string; title: string; desc?: string; defaultValue: string; options: { value: string; label: string }[] }
  | { kind: "text"; key: string; title: string; desc?: string; defaultValue: string; placeholder?: string; mono?: boolean }
  | { kind: "secret"; key: string; title: string; desc?: string; placeholder?: string }
  | { kind: "textarea"; key: string; title: string; desc?: string; defaultValue: string; rows?: number; defaultsKey?: string }
  | { kind: "action"; title: string; desc?: string; actionLabel: string; action: string; danger?: boolean; confirmLabel?: string }
  | { kind: "readout"; title: string; desc?: string; value: string }
  | { kind: "microphone"; key: string; title: string; desc?: string }
  | { kind: "language"; key: string; title: string; desc?: string }
  | { kind: "mode"; title: string; desc?: string }
  | { kind: "note"; title: string; desc: string; tone?: "info" | "good" }
  | { kind: "permissions"; title: string };

export type Row = RowBase & {
  /** Show this only while the condition holds. */
  when?: Condition;
  /** A glyph beside the title, so the row reads at a glance. */
  icon?: string;
  /** Shown from an info dot beside the title, on hover or focus. */
  info?: string;
  /**
   * How far under its parent this row sits.
   *
   * A setting that only exists because the one above it is on is drawn as its
   * child — indented, on a rail — rather than as the next item in a flat list.
   * Ticking a box and having things appear *inside* it is the whole point:
   * nothing turns on out of sight.
   */
  depth?: 1 | 2;
  /**
   * Keys to switch off along with this one.
   *
   * A stage that feeds another is not merely hidden when its parent is off —
   * it is actually turned off, so what is stored always matches what the page
   * says is happening.
   */
  cascadeOff?: string[];
};

/** Show this only when `key` currently equals one of `equals`. */
export interface Condition {
  key: string;
  equals: string[];
}

export interface Group {
  label?: string;
  /** A short statement of what this group decides, shown under its title. */
  caption?: string;
  /** Rendered as a chip beside the title: where this stage runs. */
  badgeKey?: string;
  rows: Row[];
  when?: Condition;
}

export interface Page {
  id: string;
  title: string;
  icon: string;
  section: "overview" | "settings" | "account";
  groups: Group[];
  /** Rendered by a dedicated component rather than from `groups`. */
  custom?: "dictionary" | "history" | "insights" | "transcribe" | "notetaker";
}

const engineOptions = [
  { value: "cloud", label: "Cloud provider" },
  { value: "local", label: "On-device (Apple)" },
];

/** Truthy values as the bridge reports them. */
export const ON = ["true", "1"];

/**
 * The three post-processing stages, in the order one feeds the next.
 *
 * `PipelineMode` in the app derives its preset from exactly these, so the
 * preset row and the toggles below it can never disagree.
 */
export const PIPELINE_KEYS = {
  cleanup: "post_processing_enabled",
  context: "context_inference_enabled",
  screenshot: "context_screenshot_enabled",
} as const;

export interface PipelinePreset {
  id: string;
  title: string;
  icon: string;
  /** Roughly how long the text takes to appear after you stop speaking. */
  wait: string;
  summary: string;
  cleanup: boolean;
  context: boolean;
  screenshot: boolean;
}

export const PIPELINE_PRESETS: PipelinePreset[] = [
  {
    id: "fast",
    title: "Fast",
    icon: "bolt",
    wait: "0s",
    summary: "Pasted exactly as transcribed. One network call, nothing to wait for.",
    cleanup: false,
    context: false,
    screenshot: false,
  },
  {
    id: "normal",
    title: "Normal",
    icon: "gauge",
    wait: "1s",
    summary: "Tidies the text and looks at the app you are in, without a picture of the screen.",
    cleanup: true,
    context: true,
    screenshot: false,
  },
  {
    id: "quality",
    title: "Quality",
    icon: "gem",
    wait: "3s",
    summary: "Everything, including a picture of the window you are dictating into.",
    cleanup: true,
    context: true,
    screenshot: true,
  },
];

export const PAGES: Page[] = [
  // Above the settings, because this is not one. The window was a pile of
  // switches with no reason to open it unless something was wrong.
  {
    id: "insights",
    title: "Insights",
    icon: "chart",
    section: "overview",
    custom: "insights",
    groups: [],
  },
  {
    id: "notetaker",
    title: "Notetaker",
    icon: "notes",
    section: "overview",
    custom: "notetaker",
    groups: [],
  },
  {
    id: "transcribe",
    title: "Transcribe a file",
    icon: "upload",
    section: "overview",
    custom: "transcribe",
    groups: [],
  },
  {
    id: "history",
    title: "History",
    icon: "clock",
    section: "overview",
    custom: "history",
    groups: [],
  },
  {
    id: "general",
    // "General" is where settings go when nobody decided where they go. This
    // page is the machine side of ZFlow — how it starts, what it listens to,
    // what it does with the text once written — so it says that instead.
    title: "System",
    icon: "sliders",
    section: "settings",
    groups: [
      {
        label: "Dictation",
        rows: [
          {
            kind: "readout",
            title: "Shortcuts",
            desc: "Hold your dictation key and speak.",
            value: "Configured in the app",
            icon: "mic",
          },
          {
            kind: "language",
            key: "transcription_language",
            title: "Dictation language",
            desc: "The language you speak. Only languages the engine you chose can actually handle are offered.",
            icon: "globe",
          },
          {
            kind: "select",
            key: "output_language",
            title: "Output language",
            desc: "Translate the cleaned transcript into this language. Leave as spoken to keep your own.",
            defaultValue: "",
            icon: "translate",
            options: [
              { value: "", label: "Same as spoken" },
              { value: "English", label: "English" },
              { value: "French", label: "French" },
              { value: "Spanish", label: "Spanish" },
              { value: "German", label: "German" },
            ],
            when: { key: "post_processing_enabled", equals: ON },
          },
        ],
      },
      {
        label: "Input",
        rows: [
          {
            kind: "microphone",
            key: "selected_microphone_id",
            title: "Microphone",
            desc: "Which input ZFlow records from.",
            icon: "mic",
          },
        ],
      },
      {
        label: "App settings",
        rows: [
          { kind: "toggle", key: "launch_at_login", title: "Launch app at login", defaultValue: false, icon: "login" },
          {
            kind: "toggle",
            key: "show_menu_bar_icon",
            title: "Show ZFlow in the menu bar",
            desc: "The menu bar icon is how you reach these settings and see when a dictation is running.",
            defaultValue: true,
            icon: "menubar",
          },
          {
            kind: "toggle",
            key: "show_app_in_dock",
            title: "Show app in dock",
            desc: "Off keeps ZFlow out of the Dock and the app switcher entirely. It stays in the menu bar.",
            defaultValue: true,
            icon: "dock",
          },
        ],
      },
      {
        label: "Sound",
        rows: [
          {
            kind: "toggle",
            key: "alert_sounds_enabled",
            title: "Dictation and notification sounds",
            defaultValue: true,
            icon: "volume",
          },
          {
            kind: "toggle",
            key: "dictation_audio_interruption_enabled",
            title: "Mute all audio while dictating",
            defaultValue: false,
            icon: "mute",
          },
        ],
      },
      // Folded in from the page that used to be called Advanced. Calling a
      // page that only held four switches "Advanced" made them look riskier
      // than they are, and hid them behind a click for no reason.
      {
        label: "Editing",
        rows: [
          {
            kind: "toggle",
            key: "command_mode_enabled",
            title: "Edit Mode",
            desc: "Select text and speak an instruction to transform it.",
            defaultValue: false,
            icon: "pencil",
          },
          {
            kind: "toggle",
            key: "press_enter_voice_command_enabled",
            title: "“Press enter” voice command",
            desc: "Saying “press enter” at the end of a dictation sends the message.",
            defaultValue: true,
            icon: "enter",
          },
        ],
      },
      {
        label: "Clipboard",
        rows: [
          {
            kind: "toggle",
            key: "preserve_clipboard",
            title: "Restore my clipboard after pasting",
            desc: "Puts back whatever you had copied once the dictation has been pasted.",
            defaultValue: true,
            icon: "clipboard",
          },
          {
            kind: "toggle",
            key: "keep_dictation_in_clipboard_history",
            title: "Keep dictations in clipboard history",
            defaultValue: false,
            icon: "clipboard",
          },
        ],
      },
      // Last, deliberately: it is the page you come back to when something
      // has stopped working, and the first place to look is what macOS is
      // still refusing.
      {
        label: "Permissions",
        caption: "What macOS has to let ZFlow do.",
        rows: [{ kind: "permissions", title: "Permissions" }],
      },
    ],
  },
  {
    id: "engines",
    // "Engines" told nobody anything. This page decides what does the
    // listening and what does the writing, so it says so — and each half is
    // self-contained: choose where it runs, and only what that choice needs
    // appears underneath.
    title: "Voice & AI",
    icon: "cpu",
    section: "settings",
    groups: [
      {
        label: "Speech to text",
        caption: "Turning what you say into words.",
        badgeKey: "transcription_engine",
        rows: [
          {
            kind: "select",
            key: "transcription_engine",
            title: "Where it runs",
            desc: "On this Mac needs macOS 26 and costs nothing. A cloud provider is usually more accurate on names and jargon.",
            defaultValue: "cloud",
            options: engineOptions,
            icon: "cpu",
          },
          {
            kind: "note",
            title: "Nothing to configure",
            desc: "Apple's on-device model handles this. It follows the dictation language in General, downloads once per language, and no key is involved.",
            tone: "good",
            when: { key: "transcription_engine", equals: ["local"] },
          },
          {
            kind: "text",
            key: "transcription_api_url",
            title: "Provider address",
            desc: "Leave empty to use the same provider as Text processing below.",
            defaultValue: "",
            placeholder: "Same as Text processing",
            mono: true,
            when: { key: "transcription_engine", equals: ["cloud"] },
          },
          {
            kind: "secret",
            key: "transcription_api_key",
            title: "Provider key",
            desc: "Only needed when the address above points somewhere else.",
            placeholder: "Same as Text processing",
            when: { key: "transcription_engine", equals: ["cloud"] },
          },
          {
            kind: "text",
            key: "transcription_model",
            title: "Model",
            defaultValue: "whisper-large-v3",
            mono: true,
            when: { key: "transcription_engine", equals: ["cloud"] },
          },
          {
            kind: "select",
            key: "transcription_request_format",
            title: "Request format",
            desc: "How the audio is sent. OpenAI and Groq take a multipart upload; ZenMux takes JSON with the audio base64 encoded.",
            defaultValue: "automatic",
            options: [
              { value: "automatic", label: "Automatic" },
              { value: "multipart", label: "Multipart form-data" },
              { value: "json_base64", label: "JSON base64" },
            ],
            when: { key: "transcription_engine", equals: ["cloud"] },
          },
          {
            kind: "toggle",
            key: "realtime_streaming_enabled",
            title: "Stream while I speak",
            desc: "Sends audio as you talk, when the provider has a realtime socket.",
            defaultValue: false,
            when: { key: "transcription_engine", equals: ["cloud"] },
          },
          {
            kind: "text",
            key: "realtime_streaming_model",
            title: "Realtime model",
            desc: "Only used for streaming. Leave empty for providers that pick their own.",
            defaultValue: "",
            placeholder: "Provider default",
            mono: true,
            depth: 1,
            when: { key: "realtime_streaming_enabled", equals: ON },
          },
        ],
      },
      {
        label: "Text processing",
        caption: "Tidying the transcript, and understanding what you are working on.",
        badgeKey: "post_processing_engine",
        rows: [
          {
            kind: "select",
            key: "post_processing_engine",
            title: "Where it runs",
            desc: "On this Mac uses Apple's language model and needs Apple Intelligence enabled. A cloud model rewrites longer text better.",
            defaultValue: "cloud",
            options: engineOptions,
            icon: "cpu",
          },
          {
            kind: "note",
            title: "Nothing to configure",
            desc: "Apple's on-device model handles cleanup and Edit Mode. Looking at your screen still uses a provider if you have one set.",
            tone: "good",
            when: { key: "post_processing_engine", equals: ["local"] },
          },
          {
            kind: "text",
            key: "api_base_url",
            title: "Provider address",
            desc: "Any OpenAI-compatible provider. Point it at localhost to use Ollama or LM Studio.",
            defaultValue: "https://api.groq.com/openai/v1",
            mono: true,
            when: { key: "post_processing_engine", equals: ["cloud"] },
          },
          {
            kind: "secret",
            key: "api_key",
            title: "Provider key",
            placeholder: "Paste your key",
            when: { key: "post_processing_engine", equals: ["cloud"] },
          },
          {
            kind: "text",
            key: "post_processing_model",
            title: "Cleanup model",
            defaultValue: "openai/gpt-oss-20b",
            mono: true,
            when: { key: "post_processing_engine", equals: ["cloud"] },
          },
          {
            kind: "text",
            key: "post_processing_fallback_model",
            title: "Fallback model",
            desc: "Used when the model above is rate limited or fails.",
            defaultValue: "qwen/qwen3.6-27b",
            mono: true,
            when: { key: "post_processing_engine", equals: ["cloud"] },
          },
        ],
      },
      {
        label: "Meetings",
        caption: "Writing down a recorded call. Separate from dictation on purpose.",
        badgeKey: "notetaker_engine",
        rows: [
          {
            kind: "select",
            key: "notetaker_engine",
            title: "Where meetings are transcribed",
            desc: "A meeting is long, and it is other people's voices. Sending one somewhere should be its own decision, so this does not follow the dictation engine.",
            defaultValue: "local",
            options: engineOptions,
            icon: "cpu",
          },
          {
            kind: "note",
            title: "Nothing leaves this Mac",
            desc: "Apple's on-device model writes up the recording, and telling the voices apart happens here too. An hour-long call costs nothing and goes nowhere.",
            tone: "good",
            when: { key: "notetaker_engine", equals: ["local"] },
          },
          {
            kind: "note",
            title: "Recordings will be uploaded",
            desc: "Both sides of every call you record go to the provider set above, in short pieces. It is charged per request, and an hour-long meeting is a lot of them.",
            tone: "info",
            when: { key: "notetaker_engine", equals: ["cloud"] },
          },
        ],
      },
      {
        label: "Looking at your screen",
        caption: "Reading the window you are dictating into, so names come out right.",
        rows: [
          {
            kind: "note",
            title: "This step always uses a provider",
            desc: "There is no on-device option for it yet. Turn off “Look at what I'm working on” in Post-Processing if you would rather nothing was sent.",
            tone: "info",
          },
          {
            kind: "text",
            key: "context_model",
            title: "Model that reads your screen",
            desc: "Needs to accept image input when a picture of the screen is included.",
            defaultValue: "qwen/qwen3.6-27b",
            mono: true,
          },
        ],
        when: { key: "context_inference_enabled", equals: ON },
      },
    ],
  },
  {
    id: "post-processing",
    title: "Post-Processing",
    icon: "sparkles",
    section: "settings",
    groups: [
      {
        label: "Mode",
        caption: "How much work happens between you stopping and the text appearing.",
        rows: [{ kind: "mode", title: "Mode" }],
      },
      {
        label: "Pipeline",
        caption: "Each stage is drawn inside the one it depends on, so nothing runs out of sight.",
        rows: [
          {
            kind: "toggle",
            key: PIPELINE_KEYS.cleanup,
            title: "Transcript cleanup",
            desc: "Fixes punctuation and removes filler. Off means the transcript is pasted exactly as transcribed.",
            defaultValue: true,
            icon: "wand",
            cascadeOff: [PIPELINE_KEYS.context, PIPELINE_KEYS.screenshot],
          },
          // The instructions come first inside each stage. They are the thing
          // anyone opens this page to read or change; the switches beside them
          // are adjustments to what the instructions already say.
          {
            kind: "textarea",
            key: "custom_system_prompt",
            title: "Cleanup instructions",
            desc: "What ZFlow tells the model about tidying up what you said. Change it only if you know what you want different.",
            defaultValue: "",
            defaultsKey: "custom_system_prompt",
            rows: 10,
            icon: "fileText",
            depth: 1,
            when: { key: PIPELINE_KEYS.cleanup, equals: ON },
          },
          {
            kind: "toggle",
            key: "preserve_exact_wording",
            title: "Preserve exact wording",
            desc: "Keeps filler, informal phrasing, and explicit language exactly as spoken.",
            defaultValue: false,
            icon: "quote",
            depth: 1,
            when: { key: PIPELINE_KEYS.cleanup, equals: ON },
          },
          {
            kind: "toggle",
            key: "instruction_execution_guard_enabled",
            title: "Instruction guard",
            desc: "Stops the cleanup model from acting on a dictation that reads like an instruction.",
            defaultValue: true,
            icon: "shield",
            depth: 1,
            when: { key: PIPELINE_KEYS.cleanup, equals: ON },
          },
          // "Context inference" named the mechanism. This names what happens.
          {
            kind: "toggle",
            key: PIPELINE_KEYS.context,
            title: "Look at what I'm working on",
            desc: "ZFlow checks which app and window you are dictating into, and any text you have selected, so names and words already on screen come out spelled right.",
            defaultValue: true,
            icon: "window",
            depth: 1,
            cascadeOff: [PIPELINE_KEYS.screenshot],
            when: { key: PIPELINE_KEYS.cleanup, equals: ON },
          },
          {
            kind: "textarea",
            key: "custom_context_prompt",
            title: "Looking instructions",
            desc: "What ZFlow tells the model to pay attention to in the window you are dictating into.",
            defaultValue: "",
            defaultsKey: "custom_context_prompt",
            rows: 7,
            icon: "fileText",
            depth: 2,
            when: { key: PIPELINE_KEYS.context, equals: ON },
          },
          {
            kind: "toggle",
            key: PIPELINE_KEYS.screenshot,
            title: "Include a picture of the screen",
            desc: "Sends an image of the window you are dictating into, so anything visible can be read too. Needs Screen Recording permission.",
            defaultValue: false,
            icon: "camera",
            depth: 2,
            when: { key: PIPELINE_KEYS.context, equals: ON },
          },
        ],
      },
      {
        label: "Vocabulary",
        caption: "Words ZFlow should always get right.",
        rows: [
          {
            kind: "textarea",
            key: "custom_vocabulary",
            title: "Custom vocabulary",
            desc: "Names, jargon and project words to keep spelled correctly. One per line, or separated by commas. This is a hint for the cleanup model — to replace one specific misspelling every time, use the Dictionary instead.",
            info: "Vocabulary is a list of correct spellings. It is handed to the cleanup model as a hint, so it only has any effect while cleanup is on, and the model can still get a word wrong.\n\nThe Dictionary is pairs instead: whenever the word on the left appears, ZFlow writes the word on the right. That one is a straight replacement — guaranteed, and it still happens with cleanup off.",
            defaultValue: "",
            rows: 4,
            icon: "book",
          },
          {
            kind: "toggle",
            key: "learned_corrections_enabled",
            title: "Learn words I correct by hand",
            desc: "When you respell a word by hand just after a dictation is pasted, ZFlow adds it to your Dictionary automatically and applies it to every later dictation.",
            info: "This fills the Dictionary for you. Dictionary entries are replaced in the text outright, so they work even when cleanup is off — unlike the vocabulary list above, which is only a hint to the model.",
            defaultValue: true,
            icon: "graduate",
            cascadeOff: ["correction_adjudication_enabled"],
          },
          {
            kind: "toggle",
            key: "correction_adjudication_enabled",
            title: "Ask the cleanup model when unsure",
            desc: "Sends the two versions of the sentence to your cleanup engine when the rules cannot tell whether an edit was a spelling fix.",
            defaultValue: false,
            icon: "scale",
            depth: 1,
            when: { key: "learned_corrections_enabled", equals: ON },
          },
        ],
      },
    ],
  },
  {
    id: "dictionary",
    title: "Dictionary",
    icon: "book",
    section: "settings",
    custom: "dictionary",
    groups: [],
  },
  {
    id: "privacy",
    title: "Data and Privacy",
    icon: "shield",
    section: "account",
    groups: [
      {
        rows: [
          {
            kind: "readout",
            title: "Where your dictation goes",
            desc: "There is no ZFlow server. Audio and transcripts go only to the provider you configure — and with both engines set to on-device, nowhere at all.",
            value: "",
            icon: "shield",
          },
          {
            kind: "toggle",
            key: "context_screenshot_enabled",
            title: "Pictures of your screen",
            desc: "When off, no screenshot is ever taken and the Screen Recording permission is never used.",
            defaultValue: false,
            icon: "camera",
          },
        ],
      },
      {
        label: "What is kept",
        caption: "All of it is on this Mac, and all of it can go.",
        rows: [
          {
            kind: "action",
            title: "Usage counts",
            desc: "The figures on Insights: how many words, how long, which apps, which days. Clearing them leaves your dictations, Dictionary and settings untouched.",
            actionLabel: "Clear the counts",
            confirmLabel: "Clear them — this cannot be undone",
            action: "resetInsights",
            icon: "chart",
          },
        ],
      },
    ],
  },
];
