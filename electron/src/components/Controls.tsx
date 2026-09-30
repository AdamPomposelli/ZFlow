import React from "react";

export function Switch({
  on,
  onChange,
  label,
  disabled,
  indicator,
}: {
  on: boolean;
  onChange?: (next: boolean) => void;
  label: string;
  disabled?: boolean;
  /**
   * Draw the switch without making it a control of its own.
   *
   * A settings row is clickable across its whole width, so the row is the
   * switch. A second switch inside it would be a second thing to tab to and
   * a second thing for a screen reader to announce, both saying the same.
   */
  indicator?: boolean;
}) {
  if (indicator) {
    return <span className="switch switch--indicator" data-on={on} aria-hidden="true" />;
  }

  return (
    <button
      className="switch no-drag"
      data-on={on}
      role="switch"
      aria-checked={on}
      aria-label={label}
      disabled={disabled}
      onClick={() => onChange?.(!on)}
    />
  );
}

export function Select({
  value,
  options,
  onChange,
  label,
}: {
  value: string;
  options: { value: string; label: string }[];
  onChange: (next: string) => void;
  label: string;
}) {
  return (
    <select
      className="select no-drag"
      aria-label={label}
      value={value}
      onChange={(event) => onChange(event.target.value)}
    >
      {options.map((option) => (
        <option key={option.value} value={option.value}>
          {option.label}
        </option>
      ))}
    </select>
  );
}

/**
 * Commits on blur and on Enter rather than on every keystroke: these write
 * straight through to the app's stored settings.
 */
export function TextField({
  value,
  onCommit,
  placeholder,
  mono,
  label,
}: {
  value: string;
  onCommit: (next: string) => void;
  placeholder?: string;
  mono?: boolean;
  label: string;
}) {
  const [draft, setDraft] = React.useState(value);
  React.useEffect(() => setDraft(value), [value]);

  return (
    <input
      className={`input no-drag${mono ? " input--mono" : ""}`}
      aria-label={label}
      style={{ width: 260 }}
      value={draft}
      placeholder={placeholder}
      onChange={(event) => setDraft(event.target.value)}
      onBlur={() => draft !== value && onCommit(draft)}
      onKeyDown={(event) => {
        if (event.key === "Enter") (event.target as HTMLInputElement).blur();
        if (event.key === "Escape") setDraft(value);
      }}
    />
  );
}

export function Button({
  children,
  onClick,
  variant = "secondary",
}: {
  children: React.ReactNode;
  onClick?: () => void;
  variant?: "secondary" | "primary" | "danger";
}) {
  const cls =
    variant === "primary" ? "btn btn--primary" : variant === "danger" ? "btn btn--danger" : "btn";
  return (
    <button className={`${cls} no-drag`} onClick={onClick}>
      {children}
    </button>
  );
}

/**
 * A credential field. The value is never read back from the app — the bridge
 * reports only whether one is set — so this shows presence and takes a new one.
 */
export function SecretField({
  present,
  onCommit,
  placeholder,
  label,
}: {
  present: boolean;
  onCommit: (next: string) => void;
  placeholder?: string;
  label: string;
}) {
  const [draft, setDraft] = React.useState("");
  const [saved, setSaved] = React.useState(false);

  const commit = () => {
    if (!draft.trim()) return;
    onCommit(draft.trim());
    setDraft("");
    setSaved(true);
    window.setTimeout(() => setSaved(false), 2200);
  };

  return (
    <div className="secret-field no-drag">
      <input
        className="input input--mono"
        type="password"
        aria-label={label}
        style={{ width: 230 }}
        value={draft}
        placeholder={present ? "••••••••••••  (saved)" : placeholder}
        onChange={(event) => setDraft(event.target.value)}
        onKeyDown={(event) => event.key === "Enter" && commit()}
      />
      <button className="btn" onClick={commit} disabled={!draft.trim()}>
        {saved ? "Saved" : "Save"}
      </button>
    </div>
  );
}

/**
 * A long-text setting.
 *
 * `fallback` is the text the app uses when this setting is empty. It is shown
 * as the real content rather than as placeholder grey, because an empty box
 * reads as "nothing is being sent", which is untrue: the built-in prompt is.
 * Editing it stores your own version; "Restore default" clears it back to
 * empty, so the app follows its own default again as it improves.
 */
export function TextArea({
  value,
  onCommit,
  rows,
  label,
  fallback,
}: {
  value: string;
  onCommit: (next: string) => void;
  rows?: number;
  label: string;
  fallback?: string;
}) {
  const usingFallback = value === "" && !!fallback;
  const shown = usingFallback ? (fallback as string) : value;
  const [draft, setDraft] = React.useState(shown);
  React.useEffect(() => setDraft(shown), [shown]);
  const dirty = draft !== shown;

  return (
    <div className="textarea-wrap no-drag">
      <textarea
        className="textarea"
        aria-label={label}
        rows={rows ?? 4}
        value={draft}
        onChange={(event) => setDraft(event.target.value)}
        onBlur={() => dirty && onCommit(draft)}
      />
      {/* Nothing to say about a field with no built-in default and no edit in
          progress, so the strip is not there rather than empty. */}
      {(fallback !== undefined || dirty) && (
        <div className="textarea-foot">
          {fallback !== undefined && (
            <span className="textarea-state">
              {usingFallback ? "Built-in default" : "Customised"}
            </span>
          )}
          {!usingFallback && fallback !== undefined && !dirty && (
            <button className="link-btn" onClick={() => onCommit("")}>
              Restore default
            </button>
          )}
          {dirty && (
            <button className="confirm-chip" onClick={() => onCommit(draft)} aria-label={`Save ${label}`}>
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round">
                <path d="m5 13 4.5 4.5L19 7" />
              </svg>
              Save
            </button>
          )}
        </div>
      )}
    </div>
  );
}

/**
 * A short explanation attached to a setting, for the question the label cannot
 * answer without becoming a paragraph.
 *
 * It opens on hover and on keyboard focus, and the text is also the accessible
 * name, so it is not information only a mouse can reach.
 */
export function InfoDot({ text }: { text: string }) {
  return (
    <span
      className="info-dot no-drag"
      tabIndex={0}
      role="note"
      aria-label={text}
      onClick={(event) => event.stopPropagation()}
      onKeyDown={(event) => event.stopPropagation()}
    >
      <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round">
        <circle cx="12" cy="12" r="9" />
        <path d="M12 11v5.2M12 7.7v.3" />
      </svg>
      <span className="info-bubble" role="tooltip">{text}</span>
    </span>
  );
}

/**
 * A button for something that cannot be undone.
 *
 * Two presses, because the first one is the one people make by accident. The
 * armed state disarms itself after a few seconds so the page never sits
 * waiting for an answer nobody meant to give.
 */
export function ConfirmButton({
  label,
  confirmLabel,
  onConfirm,
}: {
  label: string;
  confirmLabel: string;
  onConfirm: () => void;
}) {
  const [armed, setArmed] = React.useState(false);

  React.useEffect(() => {
    if (!armed) return;
    const timer = window.setTimeout(() => setArmed(false), 5000);
    return () => window.clearTimeout(timer);
  }, [armed]);

  return (
    <button
      className={`btn no-drag${armed ? " btn--danger" : ""}`}
      onClick={() => {
        if (!armed) {
          setArmed(true);
          return;
        }
        setArmed(false);
        onConfirm();
      }}
    >
      {armed ? confirmLabel : label}
    </button>
  );
}
