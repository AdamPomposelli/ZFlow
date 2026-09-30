import React from "react";
import { Icon } from "../icons";

export interface LanguageEntry {
  code: string;
  name: string;
  nativeName: string;
  installed: boolean;
}

export interface LanguageCatalog {
  engine: string;
  ready: boolean;
  autoDetectLabel: string;
  autoDetectDesc: string;
  items: LanguageEntry[];
}

/**
 * The dictation language picker.
 *
 * The list is whatever the *active engine* reported, not a fixed table: pick
 * on-device and you see the locales Apple actually has on this Mac, with the
 * ones already downloaded marked. So a language can never be chosen here that
 * the engine would then reject.
 *
 * ZFlow sends exactly one language to the engine — Whisper takes a single
 * `language`, and Apple's transcriber runs one locale at a time — so the
 * selection is one language or auto, and the panel says so rather than
 * implying a set.
 */
export function LanguageModal({
  catalog,
  value,
  onSave,
  onClose,
}: {
  catalog: LanguageCatalog | null;
  value: string;
  onSave: (next: string) => void;
  onClose: () => void;
}) {
  const [draft, setDraft] = React.useState(value);
  const [query, setQuery] = React.useState("");
  const searchRef = React.useRef<HTMLInputElement>(null);

  React.useEffect(() => setDraft(value), [value]);
  React.useEffect(() => {
    searchRef.current?.focus();
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") onClose();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  const items = catalog?.items ?? [];
  const needle = query.trim().toLowerCase();
  const shown = needle
    ? items.filter(
        (item) =>
          item.name.toLowerCase().includes(needle) ||
          item.nativeName.toLowerCase().includes(needle) ||
          item.code.toLowerCase().startsWith(needle)
      )
    : items;

  const selected = items.find((item) => item.code === draft) ?? null;
  const auto = draft === "";

  return (
    <div className="modal-scrim no-drag" onMouseDown={onClose}>
      <div
        className="modal"
        role="dialog"
        aria-modal="true"
        aria-label="Dictation language"
        onMouseDown={(event) => event.stopPropagation()}
      >
        <header className="modal-head">
          <div>
            <h2 className="modal-title">Dictation language</h2>
            <p className="modal-sub">
              {catalog?.engine === "local"
                ? "Languages Apple's on-device model can transcribe on this Mac."
                : "Languages your transcription provider accepts."}{" "}
              ZFlow sends one language per dictation.
            </p>
          </div>
          <button className="icon-btn" aria-label="Close" onClick={onClose}>
            <Icon.close />
          </button>
        </header>

        <div className="modal-search">
          <Icon.search />
          <input
            ref={searchRef}
            className="modal-search-input"
            placeholder="Search a language"
            aria-label="Search a language"
            value={query}
            onChange={(event) => setQuery(event.target.value)}
          />
          {query && (
            <button className="icon-btn" aria-label="Clear search" onClick={() => setQuery("")}>
              <Icon.close />
            </button>
          )}
        </div>

        <div className="modal-body">
          {shown.length === 0 ? (
            <p className="modal-empty">
              {catalog === null
                ? "Reading the language list from ZFlow…"
                : `No language matches “${query}”.`}
            </p>
          ) : (
            <div className="lang-grid">
              {shown.map((item) => (
                <button
                  key={item.code}
                  className="lang-cell no-drag"
                  data-selected={item.code === draft}
                  onClick={() => setDraft(item.code)}
                >
                  <span className="lang-native">{item.nativeName}</span>
                  <span className="lang-name">{item.name}</span>
                  {/* On-device only: a language that still has to download
                      once before the first dictation in it. */}
                  {catalog?.engine === "local" && !item.installed && (
                    <span className="lang-note" title="Downloads the first time you use it">
                      <Icon.download />
                      Not downloaded
                    </span>
                  )}
                </button>
              ))}
            </div>
          )}
        </div>

        <footer className="modal-foot">
          <div className="modal-selected">
            <p className="modal-selected-label">Selected</p>
            {auto ? (
              <span className="chip chip--auto">{catalog?.autoDetectLabel ?? "Auto-detect"}</span>
            ) : (
              <span className="chip">
                {selected ? selected.nativeName : draft}
                <button
                  className="chip-x"
                  aria-label="Remove selected language"
                  onClick={() => setDraft("")}
                >
                  <Icon.close />
                </button>
              </span>
            )}
          </div>

          <label className="modal-auto">
            <span>
              <span className="modal-auto-title">{catalog?.autoDetectLabel ?? "Auto-detect"}</span>
              <span className="modal-auto-desc">{catalog?.autoDetectDesc ?? ""}</span>
            </span>
            <button
              className="switch no-drag"
              role="switch"
              aria-checked={auto}
              aria-label={catalog?.autoDetectLabel ?? "Auto-detect"}
              data-on={auto}
              onClick={() => setDraft(auto ? (selected?.code ?? items[0]?.code ?? "") : "")}
            />
          </label>

          <button className="btn btn--primary no-drag" onClick={() => { onSave(draft); onClose(); }}>
            Save and close
          </button>
        </footer>
      </div>
    </div>
  );
}
