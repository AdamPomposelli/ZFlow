import React from "react";

export interface HistoryItem {
  id: string;
  timestamp: string;
  transcript: string;
  rawTranscript: string;
  cleanedTranscript: string;
  status: string;
  debugStatus: string;
  app: string;
  windowTitle: string;
  contextSummary: string;
  contextPrompt: string;
  postProcessingPrompt: string;
  systemPrompt: string;
  screenshotStatus: string;
  selectedText: string;
  hasAudio: boolean;
}

function Step({
  index,
  title,
  note,
  children,
}: {
  index: number;
  title: string;
  /** The one-line answer to "what happened here", beside the heading. */
  note?: { text: string; tone?: "good" | "bad" | "muted" };
  children?: React.ReactNode;
}) {
  return (
    <div className="step">
      <span className="step-number">{index}</span>
      <div className="step-body">
        <p className="step-title">
          {title}
          {note && <span className={`step-note step-note--${note.tone ?? "muted"}`}>{note.text}</span>}
        </p>
        {children}
      </div>
    </div>
  );
}

function Detail({ label, value }: { label: string; value: string }) {
  if (!value) return null;
  return (
    <p className="step-detail">
      <span>{label}</span>
      <em>{value}</em>
    </p>
  );
}

/**
 * The screenshot that was actually sent, fetched only when the row is open.
 *
 * "available (image/jpeg)" told you a picture existed and nothing about what
 * was in it, which is the only question worth asking about a screenshot sent
 * off this machine. It is loaded one run at a time — never as part of the
 * history listing, which polls in the background.
 */
function Shot({ id, status }: { id: string; status: string }) {
  const [src, setSrc] = React.useState<string | null>(null);
  const [full, setFull] = React.useState(false);
  const available = status.startsWith("available");

  React.useEffect(() => {
    if (!available) return;
    let cancelled = false;
    window.zflow?.screenshot(id).then((data) => {
      if (!cancelled) setSrc(data);
    });
    return () => {
      cancelled = true;
    };
  }, [id, available]);

  if (!available) {
    return (
      <p className="step-detail">
        <span>Picture</span>
        {/* The app writes these capitalised ("Disabled in Settings"); they
            continue a sentence here. */}
        <em className="muted">none taken — {status.charAt(0).toLowerCase() + status.slice(1)}</em>
      </p>
    );
  }

  return (
    <>
      <div className="shot">
        {src ? (
          <button className="shot-thumb no-drag" onClick={() => setFull(true)} title="Click to enlarge">
            <img src={src} alt="The screen as it was sent for context" />
          </button>
        ) : (
          <div className="shot-thumb shot-thumb--loading" aria-label="Loading the picture" />
        )}
        <p className="shot-caption">This is what was sent. Click to enlarge.</p>
      </div>

      {full && src && (
        <div className="modal-scrim no-drag" onMouseDown={() => setFull(false)}>
          <img className="shot-full" src={src} alt="The screen as it was sent for context" />
        </div>
      )}
    </>
  );
}

/** The pipeline behind one run: what was seen, what was heard, what was written. */
function Expanded({ item }: { item: HistoryItem }) {
  const failed = item.status.startsWith("Error");
  // "Claude — Claude" is not two facts. Only show the window when it adds one.
  const where = item.windowTitle && item.windowTitle !== item.app
    ? `${item.app} — ${item.windowTitle}`
    : item.app;

  const looked = Boolean(item.contextSummary || item.screenshotStatus.startsWith("available"));
  const cleaned = item.cleanedTranscript.trim();
  const raw = item.rawTranscript.trim();
  const cleanupRan = cleaned.length > 0;
  const changed = cleanupRan && cleaned !== raw;

  return (
    <div className="history-detail">
      <Step
        index={1}
        title="Looked at your screen"
        note={looked ? { text: where || "unknown app", tone: "muted" } : { text: "skipped", tone: "muted" }}
      >
        {looked ? (
          <>
            <Detail label="Understood as" value={item.contextSummary} />
            <Detail label="You had selected" value={item.selectedText} />
            <Shot id={item.id} status={item.screenshotStatus} />
            {item.contextPrompt && (
              <details className="step-more">
                <summary>The instructions it was given</summary>
                <pre>{item.contextPrompt}</pre>
              </details>
            )}
          </>
        ) : (
          <p className="step-detail step-detail--plain">
            This step was turned off, so nothing about your screen was read or sent.
          </p>
        )}
      </Step>

      <Step
        index={2}
        title="Heard you say"
        note={raw ? undefined : { text: failed ? "did not finish" : "nothing heard", tone: "bad" }}
      >
        {raw && <pre className="step-text">{raw}</pre>}
      </Step>

      <Step
        index={3}
        title="Tidied it into"
        note={
          failed
            ? { text: item.status, tone: "bad" }
            : !raw
              ? { text: "nothing to tidy", tone: "muted" }
              : !cleanupRan
                ? { text: "cleanup off — pasted as heard", tone: "muted" }
                : changed
                  ? { text: "changed", tone: "good" }
                  : { text: "nothing to change", tone: "muted" }
        }
      >
        {failed ? (
          <p className="step-detail step-detail--error step-detail--plain">{item.debugStatus || item.status}</p>
        ) : (
          cleanupRan && changed && <pre className="step-text">{cleaned}</pre>
        )}
        {item.postProcessingPrompt && (
          <details className="step-more">
            <summary>What was sent to the model</summary>
            <pre>{item.postProcessingPrompt}</pre>
          </details>
        )}
        {item.systemPrompt && (
          <details className="step-more">
            <summary>The instructions it was given</summary>
            <pre>{item.systemPrompt}</pre>
          </details>
        )}
      </Step>
    </div>
  );
}

/**
 * Throwing a run away.
 *
 * Two presses. A dictation is small, but it is gone for good, and the icon
 * sits a few pixels from the row people click to read one. The armed state
 * lapses on its own so a row never sits waiting for an answer.
 */
function DeleteRun({ onDelete, label }: { onDelete: () => void; label: string }) {
  const [armed, setArmed] = React.useState(false);

  React.useEffect(() => {
    if (!armed) return;
    const timer = window.setTimeout(() => setArmed(false), 4000);
    return () => window.clearTimeout(timer);
  }, [armed]);

  return (
    <button
      className="history-delete no-drag"
      data-armed={armed}
      aria-label={armed ? `Confirm deleting ${label}` : `Delete ${label}`}
      title={armed ? "Press again to delete" : "Delete this dictation"}
      onClick={(event) => {
        event.stopPropagation();
        if (!armed) {
          setArmed(true);
          return;
        }
        setArmed(false);
        onDelete();
      }}
    >
      {armed ? (
        <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
          <path d="m5 13 4.5 4.5L19 7" />
        </svg>
      ) : (
        <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round">
          <path d="M4 7h16M9 7V5h6v2M7 7l1 13h8l1-13" />
        </svg>
      )}
    </button>
  );
}

export function History({
  items,
  onDelete,
}: {
  items: HistoryItem[];
  onDelete: (id: string) => void;
}) {
  const [openId, setOpenId] = React.useState<string | null>(null);

  if (items.length === 0) {
    return <p className="empty-note">Nothing dictated yet.</p>;
  }

  const byDay = new Map<string, HistoryItem[]>();
  for (const item of items) {
    const day = new Date(item.timestamp).toDateString();
    if (!byDay.has(day)) byDay.set(day, []);
    byDay.get(day)!.push(item);
  }
  const today = new Date().toDateString();

  return (
    <>
      {[...byDay.entries()].map(([day, dayItems]) => (
        <section key={day}>
          <h2 className="group-label">{day === today ? "Today" : day}</h2>
          <div className="card">
            {dayItems.map((item) => {
              const open = openId === item.id;
              const failed = item.status.startsWith("Error");
              return (
                <div className={`history-entry${open ? " is-open" : ""}`} key={item.id}>
                  <button
                    className="history-row no-drag"
                    aria-expanded={open}
                    onClick={() => setOpenId(open ? null : item.id)}
                  >
                    <span className="history-time">
                      {new Date(item.timestamp).toLocaleTimeString([], {
                        hour: "numeric",
                        minute: "2-digit",
                      })}
                    </span>
                    <span className={`history-text${failed ? " history-text--error" : ""}`}>
                      {item.transcript || (failed ? "Dictation failed" : "(no transcript)")}
                    </span>
                    <svg
                      className="history-chevron"
                      width="16" height="16" viewBox="0 0 24 24"
                      fill="none" stroke="currentColor" strokeWidth="1.8"
                      strokeLinecap="round" strokeLinejoin="round"
                    >
                      <path d="m8 5 7 7-7 7" />
                    </svg>
                  </button>
                  {/* Outside the row button: a button inside a button is not
                      something a browser or a screen reader will honour. */}
                  <DeleteRun
                    label={item.transcript ? `“${item.transcript.slice(0, 40)}”` : "this dictation"}
                    onDelete={() => {
                      if (open) setOpenId(null);
                      onDelete(item.id);
                    }}
                  />
                  {open && <Expanded item={item} />}
                </div>
              );
            })}
          </div>
        </section>
      ))}
    </>
  );
}
