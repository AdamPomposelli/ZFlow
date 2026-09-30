import React from "react";
import { PAGES, PIPELINE_KEYS, type Condition, type Page, type Row } from "./settings-schema";
import { Icon } from "./icons";
import { Select, Switch, TextField, Button, SecretField, TextArea, InfoDot, ConfirmButton } from "./components/Controls";
import { Permissions } from "./components/Permissions";
import { Dictionary, type Entry } from "./components/Dictionary";
import { History, type HistoryItem } from "./components/History";
import { Insights, type InsightsData } from "./components/Insights";
import { AudioDrop } from "./components/AudioDrop";
import { Notetaker } from "./components/Notetaker";
import { ModeSelector, type PipelineState } from "./components/ModeSelector";
import { LanguageModal, type LanguageCatalog } from "./components/LanguageModal";

declare global {
  interface Window {
    zflow?: {
      settings: () => Promise<Record<string, unknown>>;
      edit: (action: string) => Promise<boolean>;
      windowAction: (action: string) => Promise<boolean>;
      write: (key: string, value: unknown) => Promise<boolean>;
      history: () => Promise<HistoryItem[]>;
      historyDelete: (id: string) => Promise<boolean>;
      dictionary: () => Promise<Entry[]>;
      status: () => Promise<{ connected: boolean; appName: string | null }>;
      dictionaryMutate: (payload: Record<string, unknown>) => Promise<boolean>;
      microphones: () => Promise<{ id: string; name: string }[]>;
      defaults: () => Promise<Record<string, string>>;
      languages: () => Promise<LanguageCatalog>;
      screenshot: (id: string) => Promise<string | null>;
      insights: () => Promise<InsightsData>;
      insightsReset: () => Promise<boolean>;
      permissions: () => Promise<unknown>;
      permissionRequest: (access: string) => Promise<boolean>;
      transcribeFile: (filePath: string) => Promise<unknown>;
      transcribeFileStatus: (id: string) => Promise<unknown>;
      filePath: (file: File) => string;
      notetaker: {
        status: () => Promise<{ screen: string; microphone: string; sources: number }>;
        modelsReady: () => Promise<boolean>;
        downloadModels: () => Promise<{ ok: boolean; error?: string }>;
        onModelProgress: (listener: (fraction: number) => void) => () => void;
        diarize: (wavPath: string) => Promise<{ speaker: number; start: number; end: number }[]>;
        request: () => Promise<{ screen: string; microphone: string; openedSettings: boolean }>;
        start: () => Promise<unknown>;
        chunk: (id: string, track: "mic" | "system", chunk: ArrayBuffer) => Promise<void>;
        stop: (id: string) => Promise<unknown>;
        meetings: (action: string, body?: Record<string, unknown>) => Promise<Record<string, unknown>>;
      };
    };
  }
}

function useBridge(activePageId: string) {
  // Which heavy resources the current page needs, read inside the poll without
  // restarting it.
  const needsHistory = React.useRef(false);
  const needsDictionary = React.useRef(false);
  needsHistory.current = activePageId === "history";
  needsDictionary.current = activePageId === "dictionary";
  const needsInsights = React.useRef(false);
  needsInsights.current = activePageId === "insights";
  const fetchedMicrophones = React.useRef(false);

  const [values, setValues] = React.useState<Record<string, unknown>>({});
  const [history, setHistory] = React.useState<HistoryItem[]>([]);
  const [dictionary, setDictionary] = React.useState<Entry[]>([]);
  const [connected, setConnected] = React.useState<boolean | null>(null);
  const [appName, setAppName] = React.useState<string | null>(null);
  const [microphones, setMicrophones] = React.useState<{ id: string; name: string }[]>([]);
  const [defaults, setDefaults] = React.useState<Record<string, string>>({});
  const [languages, setLanguages] = React.useState<LanguageCatalog | null>(null);
  const [insights, setInsights] = React.useState<InsightsData | null>(null);
  const [revision, setRevision] = React.useState(0);
  const fetchedDefaults = React.useRef(false);
  // Which engine the language list was fetched for. The two engines support
  // different languages, so a stale list would offer the wrong ones.
  const languageEngine = React.useRef<string | null>(null);

  React.useEffect(() => {
    const bridge = window.zflow;
    if (!bridge) {
      // Running in a plain browser for layout work.
      setConnected(false);
      return;
    }
    let cancelled = false;

    const load = async () => {
      const state = await bridge.status();
      if (cancelled) return;
      setConnected(state.connected);
      setAppName(state.appName);
      if (!state.connected) return;
      // Settings are cheap; history and the dictionary are not, and each
      // request is served on the app's main thread. Fetch the heavy ones only
      // for the page actually being looked at, so polling never competes with
      // a dictation starting.
      const settings = await bridge.settings();
      if (cancelled) return;
      setValues(settings);

      if (needsHistory.current) {
        const runs = await bridge.history();
        if (!cancelled) setHistory(runs);
      }
      if (needsDictionary.current) {
        const words = await bridge.dictionary();
        if (!cancelled) setDictionary(words);
      }
      if (needsInsights.current) {
        const usage = await bridge.insights();
        if (!cancelled) setInsights(usage);
      }
      // Through a ref: the effect's closure would otherwise capture an empty
      // list forever and re-fetch the device list on every poll.
      if (!fetchedMicrophones.current) {
        const mics = await bridge.microphones();
        fetchedMicrophones.current = true;
        if (!cancelled) setMicrophones(mics);
      }
      // The built-in prompt text never changes while the app runs.
      if (!fetchedDefaults.current) {
        const builtIn = await bridge.defaults();
        fetchedDefaults.current = true;
        if (!cancelled) setDefaults(builtIn);
      }
      const engine = String(settings.transcription_engine ?? "cloud");
      if (languageEngine.current !== engine) {
        const catalog = await bridge.languages();
        languageEngine.current = engine;
        if (!cancelled) setLanguages(catalog);
      }
    };

    load();
    // The native settings can change the same state, so re-read periodically
    // rather than assuming this window is the only writer.
    const timer = setInterval(load, 6000);
    return () => {
      cancelled = true;
      clearInterval(timer);
    };
  }, [revision, activePageId]);

  const deleteRun = React.useCallback(async (id: string) => {
    await window.zflow?.historyDelete(id);
    // Re-read rather than drop it locally: the app decides what is gone.
    const runs = await window.zflow?.history();
    if (runs) setHistory(runs);
  }, []);

  const mutateDictionary = React.useCallback(async (payload: Record<string, unknown>) => {
    await window.zflow?.dictionaryMutate(payload);
    // Re-read rather than guess: the app applies its own rules to an edit and
    // can legitimately refuse one.
    const words = await window.zflow?.dictionary();
    if (words) setDictionary(words);
  }, []);

  const write = React.useCallback((key: string, value: unknown) => {
    setValues((prev) => ({ ...prev, [key]: value }));
    window.zflow?.write(key, value);
  }, []);

  return {
    values,
    write,
    history,
    dictionary,
    connected,
    appName,
    microphones,
    defaults,
    languages,
    insights,
    deleteRun,
    resetInsights: async () => {
      await window.zflow?.insightsReset();
      const usage = await window.zflow?.insights();
      if (usage) setInsights(usage);
    },
    mutateDictionary,
  };
}

/**
 * Whether a conditional row or group applies right now.
 *
 * This is what makes the page readable without reading it: choose on-device
 * and the provider fields are not greyed out, they are simply not there, so
 * what remains on screen is exactly what that choice needs.
 */
function matches(condition: Condition | undefined, values: Record<string, unknown>): boolean {
  if (!condition) return true;
  return condition.equals.includes(resolved(condition.key, values).toLowerCase());
}

/**
 * The effective value of a key: what the app reports, or the schema's default
 * when it has never been written. Conditions have to agree with the control
 * beside them — a select showing "Cloud provider" while the rows it gates stay
 * hidden is worse than no conditions at all.
 */
const DEFAULTS: Record<string, string> = (() => {
  const map: Record<string, string> = {};
  for (const page of PAGES) {
    for (const group of page.groups) {
      for (const row of group.rows) {
        if (!("key" in row)) continue;
        if (row.kind === "toggle") map[row.key] = String(row.defaultValue);
        else if ("defaultValue" in row) map[row.key] = String(row.defaultValue);
      }
    }
  }
  return map;
})();

function resolved(key: string, values: Record<string, unknown>): string {
  const raw = values[key];
  if (raw === undefined || raw === null || raw === "") return DEFAULTS[key] ?? "";
  if (typeof raw === "boolean") return String(raw);
  if (typeof raw === "number") return raw === 0 ? "false" : "true";
  return String(raw);
}

function boolOf(raw: unknown, fallback: boolean): boolean {
  if (raw === undefined || raw === null) return fallback;
  if (typeof raw === "boolean") return raw;
  if (typeof raw === "number") return raw !== 0;
  const text = String(raw).toLowerCase();
  return text === "1" || text === "true" || text === "yes";
}

function stringOf(raw: unknown, fallback: string): string {
  if (raw === undefined || raw === null) return fallback;
  return String(raw);
}

interface RowContext {
  values: Record<string, unknown>;
  write: (key: string, value: unknown) => void;
  microphones: { id: string; name: string }[];
  defaults: Record<string, string>;
  languages: LanguageCatalog | null;
  openLanguagePicker: () => void;
  runAction: (action: string) => void;
}

/** The label a language code should read as in the closed row. */
function languageLabel(code: string, catalog: LanguageCatalog | null): string {
  if (code === "") return catalog?.autoDetectLabel ?? "Auto-detect";
  const found = catalog?.items.find((item) => item.code === code);
  return found ? `${found.nativeName} · ${found.name}` : code.toUpperCase();
}

function RowView({ row, ctx }: { row: Row; ctx: RowContext }) {
  const { values, write, microphones, defaults, languages, openLanguagePicker } = ctx;

  const control = (() => {
    switch (row.kind) {
      case "toggle":
        return <Switch indicator label={row.title} on={boolOf(values[row.key], row.defaultValue)} />;
      case "select":
        return (
          <Select
            label={row.title}
            value={stringOf(values[row.key], row.defaultValue)}
            options={row.options}
            onChange={(next) => write(row.key, next)}
          />
        );
      case "text":
        return (
          <TextField
            label={row.title}
            value={stringOf(values[row.key], row.defaultValue)}
            placeholder={row.placeholder}
            mono={row.mono}
            onCommit={(next) => write(row.key, next)}
          />
        );
      case "action":
        return row.confirmLabel ? (
          <ConfirmButton
            label={row.actionLabel}
            confirmLabel={row.confirmLabel}
            onConfirm={() => ctx.runAction(row.action)}
          />
        ) : (
          <Button
            variant={row.danger ? "danger" : "secondary"}
            onClick={() => ctx.runAction(row.action)}
          >
            {row.actionLabel}
          </Button>
        );
      case "secret":
        return (
          <SecretField
            label={row.title}
            present={stringOf(values[row.key], "") === "set"}
            placeholder={row.placeholder}
            onCommit={(next) => write(row.key, next)}
          />
        );
      case "textarea":
        return (
          <TextArea
            label={row.title}
            rows={row.rows}
            value={stringOf(values[row.key], row.defaultValue)}
            fallback={row.defaultsKey ? defaults[row.defaultsKey] : undefined}
            onCommit={(next) => write(row.key, next)}
          />
        );
      case "microphone":
        return (
          <Select
            label={row.title}
            value={stringOf(values[row.key], "default")}
            options={
              microphones.length
                ? microphones.map((mic) => ({ value: mic.id, label: mic.name }))
                : [{ value: "default", label: "System default" }]
            }
            onChange={(next) => write(row.key, next)}
          />
        );
      case "language":
        return (
          <button className="picker no-drag" onClick={openLanguagePicker}>
            {languageLabel(stringOf(values[row.key], ""), languages)}
            <Icon.chevron />
          </button>
        );
      case "mode":
        return null;
      case "readout":
        return row.value ? <span className="value">{row.value}</span> : null;
      case "note":
        return null;
      case "permissions":
        return null;
    }
  })();

  // A section of its own: the rows come from the system, not the schema.
  if (row.kind === "permissions") return <Permissions />;

  if (row.kind === "note") {
    return (
      <div className={`note note--${row.tone ?? "info"}`}>
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
          {row.tone === "good" ? <path d="m5 13 4.5 4.5L19 7" /> : <><circle cx="12" cy="12" r="9" /><path d="M12 11v5M12 7.6v.4" /></>}
        </svg>
        <div>
          <p className="note-title">{row.title}</p>
          <p className="note-desc">{row.desc}</p>
        </div>
      </div>
    );
  }

  // The mode cards are the row: a title and a control on the right would just
  // repeat what the cards already say.
  if (row.kind === "mode") {
    const state: PipelineState = {
      cleanup: boolOf(values[PIPELINE_KEYS.cleanup], true),
      context: boolOf(values[PIPELINE_KEYS.context], true),
      screenshot: boolOf(values[PIPELINE_KEYS.screenshot], true),
    };
    return (
      <div className="row row--bare">
        <ModeSelector
          state={state}
          onPick={(preset) => {
            write(PIPELINE_KEYS.cleanup, preset.cleanup);
            write(PIPELINE_KEYS.context, preset.context);
            write(PIPELINE_KEYS.screenshot, preset.screenshot);
          }}
        />
      </div>
    );
  }

  // A prompt or a vocabulary list needs the width of the card, so those rows
  // stack instead of putting the control on the right.
  const stacked = row.kind === "textarea";
  const Glyph = row.icon ? Icon[row.icon] : undefined;
  const nesting = row.depth ? ` row--depth${row.depth}` : "";

  const body = (
    <>
      <div className="row-text">
        <p className="row-title">
          {Glyph && (
            <span className="row-glyph" aria-hidden="true">
              <Glyph />
            </span>
          )}
          {row.title}
          {row.info && <InfoDot text={row.info} />}
        </p>
        {row.desc && <p className="row-desc">{row.desc}</p>}
      </div>
      {control && <div className="row-control">{control}</div>}
    </>
  );

  // The whole row is the switch, not just the switch.
  //
  // Hitting a 46px target to turn something on is a needlessly good aim to
  // ask for, and the title and the description are the part people read and
  // point at. So the row carries the role, the focus and the click, and the
  // switch drawn on the right is only the picture of the answer.
  if (row.kind === "toggle") {
    const on = boolOf(values[row.key], row.defaultValue);
    const flip = () => {
      write(row.key, !on);
      // A stage that feeds this one is switched off too, rather than left on
      // and merely hidden: the stored state and the page have to say the same
      // thing.
      if (on) for (const key of row.cascadeOff ?? []) write(key, false);
    };

    return (
      <div
        className={`row row--switchable no-drag${nesting}`}
        role="switch"
        aria-checked={on}
        aria-label={row.title}
        tabIndex={0}
        onClick={flip}
        onKeyDown={(event) => {
          if (event.key !== " " && event.key !== "Enter") return;
          // Space would otherwise scroll the page out from under the row.
          event.preventDefault();
          flip();
        }}
      >
        {body}
      </div>
    );
  }

  return <div className={`row${stacked ? " row--stacked" : ""}${nesting}`}>{body}</div>;
}

function PageView({ page, ctx }: { page: Page; ctx: RowContext }) {
  return (
    <>
      {page.groups
        .filter((group) => matches(group.when, ctx.values))
        .map((group, index) => {
          const rows = group.rows.filter((row) => matches(row.when, ctx.values));
          if (rows.length === 0) return null;
          const badge = group.badgeKey ? resolved(group.badgeKey, ctx.values) : "";

          return (
            <section key={group.label ?? index}>
              {group.label && (
                <div className="group-head">
                  <h2 className="group-label">{group.label}</h2>
                  {badge && (
                    <span className={`badge badge--${badge === "local" ? "local" : "cloud"}`}>
                      {badge === "local" ? "On this Mac" : "Cloud"}
                    </span>
                  )}
                  {group.caption && <p className="group-caption">{group.caption}</p>}
                </div>
              )}
              <div className="card">
                {rows.map((row) => (
                  <RowView key={row.title} row={row} ctx={ctx} />
                ))}
              </div>
            </section>
          );
        })}
    </>
  );
}

/**
 * The keyboard commands this window would get from a menu bar, if it had one.
 *
 * It does not: it runs as an accessory process so ZFlow keeps a single Dock
 * icon, and macOS gives accessory apps no menu bar. Without this, Command-V
 * does nothing in a window whose whole job includes pasting an API key, and
 * Command-Q does nothing at all.
 */
function useWindowShortcuts(): void {
  React.useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (!event.metaKey || event.ctrlKey || event.altKey) return;
      const bridge = window.zflow;
      if (!bridge) return;

      const key = event.key.toLowerCase();
      const edits: Record<string, string> = {
        c: "copy",
        x: "cut",
        v: "paste",
        a: "selectAll",
      };
      if (key === "z") {
        void bridge.edit(event.shiftKey ? "redo" : "undo");
      } else if (edits[key]) {
        void bridge.edit(edits[key]);
      } else if (key === "w") {
        void bridge.windowAction("close");
      } else if (key === "m") {
        void bridge.windowAction("minimize");
      } else if (key === "q") {
        void bridge.windowAction("quit");
      } else {
        return;
      }
      event.preventDefault();
    };

    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, []);
}

/**
 * Opens on the permissions when something macOS has to allow is still
 * missing.
 *
 * The app opens this window at launch in that case, instead of a blocking
 * alert. Landing on Insights would leave the one thing that matters a page
 * away; so the first look decides, once, and never takes over navigation
 * after that.
 */
function useLandOnMissingPermissions(setActiveId: (id: string) => void) {
  React.useEffect(() => {
    let cancelled = false;
    const look = async (attempt: number) => {
      const report = (await window.zflow?.permissions().catch(() => null)) as
        | { items: unknown[]; outstanding: number }
        | null
        | undefined;
      if (cancelled) return;
      // No items means the bridge is not up yet, not that nothing is missing.
      if (!report || report.items.length === 0) {
        if (attempt < 3) window.setTimeout(() => void look(attempt + 1), 1000);
        return;
      }
      if (report.outstanding === 0) return;
      setActiveId("general");
      window.setTimeout(() => {
        document.querySelector(".row--permission")?.scrollIntoView({ block: "center" });
      }, 350);
    };
    void look(0);
    return () => {
      cancelled = true;
    };
  }, [setActiveId]);
}

export default function App() {
  useWindowShortcuts();
  const [activeId, setActiveId] = React.useState(PAGES[0].id);
  useLandOnMissingPermissions(setActiveId);
  const [languagePickerOpen, setLanguagePickerOpen] = React.useState(false);
  const {
    values,
    write,
    history,
    dictionary,
    connected,
    appName,
    microphones,
    defaults,
    languages,
    insights,
    deleteRun,
    resetInsights,
    mutateDictionary,
  } = useBridge(activeId);
  const active = PAGES.find((page) => page.id === activeId) ?? PAGES[0];

  const ctx = {
    values,
    write,
    microphones,
    defaults,
    languages,
    openLanguagePicker: () => setLanguagePickerOpen(true),
    runAction: (action: string) => {
      if (action === "resetInsights") void resetInsights();
    },
  };

  const sections: { key: "overview" | "settings" | "account"; label: string }[] = [
    { key: "overview", label: "ZFlow" },
    { key: "settings", label: "Settings" },
    { key: "account", label: "Account" },
  ];

  return (
    <div className="settings">
      <nav className="settings-sidebar drag">
        {sections.map((section) => {
          const pages = PAGES.filter((page) => page.section === section.key);
          if (pages.length === 0) return null;
          return (
            <div className="sidebar-group" key={section.key}>
              <p className="sidebar-group-label">{section.label}</p>
              {pages.map((page) => {
                const Glyph = Icon[page.icon] ?? Icon.sliders;
                return (
                  <button
                    key={page.id}
                    className="sidebar-item no-drag"
                    aria-current={page.id === activeId ? "page" : undefined}
                    onClick={() => setActiveId(page.id)}
                  >
                    <Glyph />
                    {page.title}
                  </button>
                );
              })}
            </div>
          );
        })}

        <div className="sidebar-footer">
          <span>{appName ?? "ZFlow"}</span>
          {connected ? <Icon.cloud /> : null}
        </div>
      </nav>

      <main className="settings-content">
        <div className="page-head drag">
          <h1 className="page-title">{active.title}</h1>
        </div>

        {connected === false && (
          <div className="bridge-banner">
            ZFlow is not running, so these settings cannot be read or changed. Start the app
            and this window will connect on its own.
          </div>
        )}

        {active.custom === "notetaker" ? (
          <Notetaker />
        ) : active.custom === "transcribe" ? (
          <AudioDrop />
        ) : active.custom === "insights" ? (
          <Insights data={insights} />
        ) : active.custom === "dictionary" ? (
          <Dictionary
            entries={dictionary}
            onAddVariant={(corrected, heard) =>
              mutateDictionary({ action: "add", corrected, original: heard })
            }
            onRemoveVariant={(id) => mutateDictionary({ action: "removeVariant", id })}
            onRename={(from, to) => mutateDictionary({ action: "rename", from, to })}
            onRemoveGroup={(corrected) => mutateDictionary({ action: "removeGroup", corrected })}
          />
        ) : active.custom === "history" ? (
          <History items={history} onDelete={deleteRun} />
        ) : (
          <PageView page={active} ctx={ctx} />
        )}
      </main>

      {languagePickerOpen && (
        <LanguageModal
          catalog={languages}
          value={stringOf(values.transcription_language, "")}
          onSave={(next) => write("transcription_language", next)}
          onClose={() => setLanguagePickerOpen(false)}
        />
      )}
    </div>
  );
}
