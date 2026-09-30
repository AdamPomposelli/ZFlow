import React from "react";
import { Icon } from "../icons";
import { startMeetingRecorder, type MeetingRecorder } from "../lib/recorder";

export interface MeetingNote {
  id: string;
  title: string;
  startedAt: string;
  durationSeconds: number;
  state: "recorded" | "transcribing" | "ready" | "failed";
  transcript: string;
  summary: string;
  speakers: string[];
  engine: string;
  error: string;
  segments: { speaker: string; text: string; start: number; end: number }[];
}

function clock(seconds: number): string {
  const total = Math.floor(seconds);
  const minutes = Math.floor(total / 60);
  return `${minutes}:${String(total % 60).padStart(2, "0")}`;
}

function Meter({ label, level, live }: { label: string; level: number; live: boolean }) {
  return (
    <div className="meter">
      <span className="meter-label">{label}</span>
      <span className="meter-track">
        <span
          className="meter-fill"
          data-silent={live && level < 0.01}
          style={{ width: `${Math.min(100, Math.round(level * 160))}%` }}
        />
      </span>
    </div>
  );
}

/**
 * Recording a meeting, and what came of the ones before it.
 *
 * The far side of a call is captured through macOS's screen-recording
 * permission — that is the only way an app can hear what the machine is
 * playing — so the page says so plainly before anything starts, rather than
 * failing with a constraints error when you press the button.
 */
export function Notetaker() {
  const [permissions, setPermissions] = React.useState<{
    screen: string;
    microphone: string;
    sources: number;
  } | null>(null);
  const [recorder, setRecorder] = React.useState<MeetingRecorder | null>(null);
  const [elapsed, setElapsed] = React.useState(0);
  const [levels, setLevels] = React.useState({ mic: 0, system: 0 });
  const [notes, setNotes] = React.useState<MeetingNote[]>([]);
  const [openId, setOpenId] = React.useState<string | null>(null);
  const [error, setError] = React.useState<string | null>(null);
  const [busy, setBusy] = React.useState(false);
  const [modelsReady, setModelsReady] = React.useState<boolean | null>(null);
  const [modelProgress, setModelProgress] = React.useState<number | null>(null);
  const [stage, setStage] = React.useState<string | null>(null);

  const refresh = React.useCallback(async () => {
    const result = (await window.zflow?.notetaker.meetings("list")) as
      | { ok: boolean; items?: MeetingNote[] }
      | undefined;
    if (result?.items) setNotes(result.items);
  }, []);

  React.useEffect(() => {
    window.zflow?.notetaker.status().then(setPermissions);
    window.zflow?.notetaker.modelsReady().then(setModelsReady);
    refresh();
  }, [refresh]);

  React.useEffect(() => window.zflow?.notetaker.onModelProgress(setModelProgress), []);

  // While anything is still being transcribed, keep asking.
  React.useEffect(() => {
    if (!notes.some((note) => note.state === "transcribing")) return;
    const timer = setInterval(refresh, 1500);
    return () => clearInterval(timer);
  }, [notes, refresh]);

  React.useEffect(() => {
    if (!recorder) return;
    const timer = setInterval(() => {
      setElapsed((seconds) => seconds + 1);
      setLevels(recorder.levels());
    }, 1000);
    return () => clearInterval(timer);
  }, [recorder]);

  const start = async () => {
    setError(null);
    setBusy(true);
    try {
      const session = await startMeetingRecorder();
      setElapsed(0);
      setRecorder(session);
      if (!session.hasSystemAudio) {
        setError(
          "Recording your microphone only — macOS did not hand over the system audio, so the other side of the call will not be captured."
        );
      }
    } catch (failure) {
      setError(failure instanceof Error ? failure.message : String(failure));
    } finally {
      setBusy(false);
    }
  };

  const stop = async () => {
    if (!recorder) return;
    setBusy(true);
    const session = recorder;
    setRecorder(null);
    try {
      setStage("Closing the recording…");
      await session.stop();

      // Who said what on the far side, before the words are asked for: the
      // turns go in with the transcription request so the lines come back
      // already named.
      let turns: { speaker: number; start: number; end: number }[] = [];
      if (session.hasSystemAudio && modelsReady) {
        setStage("Telling the voices apart…");
        try {
          turns = await window.zflow!.notetaker.diarize(session.systemTrackPath);
        } catch {
          turns = [];
        }
      }

      setStage("Writing it up…");
      await window.zflow?.notetaker.meetings("transcribe", { id: session.id, turns });
      setOpenId(session.id);
      await refresh();
      // The summary is asked for once there is something to summarise; it
      // arrives on its own and the list is already polling for it.
      void summarise(session.id, { silent: true });
    } catch (failure) {
      setError(failure instanceof Error ? failure.message : String(failure));
    } finally {
      setStage(null);
      setBusy(false);
    }
  };

  const summarise = React.useCallback(
    async (id: string, options?: { silent?: boolean }) => {
      // Wait for the transcript before asking: the request is built from it.
      for (let attempt = 0; attempt < 120; attempt++) {
        const got = (await window.zflow?.notetaker.meetings("get", { id })) as
          | { note?: MeetingNote }
          | undefined;
        const state = got?.note?.state;
        if (state === "ready") break;
        if (state === "failed") return;
        await new Promise((resolve) => setTimeout(resolve, 1000));
      }
      const result = (await window.zflow?.notetaker.meetings("summarise", { id })) as
        | { ok: boolean; error?: string }
        | undefined;
      if (!result?.ok && !options?.silent) setError(result?.error ?? "The summary did not start.");
      // It lands in the note when it is done; keep looking for a little while.
      for (let attempt = 0; attempt < 60; attempt++) {
        await new Promise((resolve) => setTimeout(resolve, 1500));
        const got = (await window.zflow?.notetaker.meetings("get", { id })) as
          | { note?: MeetingNote }
          | undefined;
        if (got?.note?.summary) break;
      }
      await refresh();
    },
    [refresh]
  );

  const remove = async (id: string) => {
    await window.zflow?.notetaker.meetings("delete", { id });
    if (openId === id) setOpenId(null);
    await refresh();
  };

  const needsPermission =
    permissions !== null && (permissions.screen !== "granted" || permissions.microphone !== "granted");

  return (
    <>
      <p className="page-lede">
        Record a call and get it back as a conversation, with who said what. Your microphone and
        everything your Mac plays are recorded as separate tracks, so your own words are never
        mistaken for anyone else's.
      </p>

      {needsPermission && (
        <div className="note note--info">
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
            <circle cx="12" cy="12" r="9" /><path d="M12 11v5M12 7.6v.4" />
          </svg>
          <div>
            <p className="note-title">macOS has to let ZFlow listen first</p>
            <p className="note-desc">
              {permissions?.microphone !== "granted" && "The microphone records your side. "}
              {permissions?.screen !== "granted" &&
                "Hearing the other side means Screen Recording, which is how macOS gates system audio — no picture of your screen is kept. "}
              Grant them to <strong>ZFlow UI</strong>, then come back.
            </p>
            <div className="job-actions" style={{ marginTop: 10, marginBottom: 0 }}>
              <button
                className="btn"
                onClick={async () => {
                  await window.zflow?.notetaker.request();
                  setPermissions(await window.zflow!.notetaker.status());
                }}
              >
                Open permissions
              </button>
            </div>
          </div>
        </div>
      )}

      {modelsReady === false && (
        <div className="note note--info">
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
            <circle cx="12" cy="12" r="9" /><path d="M12 11v5M12 7.6v.4" />
          </svg>
          <div>
            <p className="note-title">Naming the other voices needs a download</p>
            <p className="note-desc">
              Two speaker models, 34 MB together, fetched once and kept on this Mac. They run
              here, on the recording — nothing is uploaded. Without them a meeting still gets
              transcribed, with the far side simply labelled “Them”.
            </p>
            <div className="job-actions" style={{ marginTop: 10, marginBottom: 0 }}>
              <button
                className="btn"
                disabled={modelProgress !== null}
                onClick={async () => {
                  setModelProgress(0);
                  const result = await window.zflow!.notetaker.downloadModels();
                  setModelProgress(null);
                  if (!result.ok) setError(result.error ?? "The download did not finish.");
                  setModelsReady(await window.zflow!.notetaker.modelsReady());
                }}
              >
                {modelProgress !== null
                  ? `Downloading… ${Math.round(modelProgress * 100)}%`
                  : "Download the speaker models"}
              </button>
            </div>
          </div>
        </div>
      )}

      <div className={`recorder${recorder ? " recorder--live" : ""}`}>
        {recorder ? (
          <>
            <span className="recorder-dot" />
            <p className="recorder-clock">{clock(elapsed)}</p>
            <div className="meters">
              <Meter label="You" level={levels.mic} live />
              <Meter label="Them" level={levels.system} live={recorder.hasSystemAudio} />
            </div>
            <button className="btn btn--primary" onClick={stop} disabled={busy}>
              Stop and transcribe
            </button>
          </>
        ) : (
          <>
            <span className="recorder-glyph">
              <Icon.mic />
            </span>
            <p className="recorder-title">Record this meeting</p>
            <p className="recorder-sub">
              Both sides are kept on this Mac. Transcription uses the engine you chose for
              meetings in Voice &amp; AI.
            </p>
            <button className="btn btn--primary" onClick={start} disabled={busy}>
              {busy ? "Starting…" : "Start recording"}
            </button>
          </>
        )}
      </div>

      {stage && <p className="job-status" style={{ textAlign: "center" }}>{stage}</p>}
      {error && <p className="drop-error">{error}</p>}

      {notes.length > 0 && (
        <section style={{ marginTop: 22 }}>
          <div className="group-head">
            <h2 className="group-label">Meetings</h2>
          </div>
          <div className="card">
            {notes.map((note) => {
              const open = openId === note.id;
              return (
                <div className={`history-entry${open ? " is-open" : ""}`} key={note.id}>
                  <button
                    className="history-row no-drag"
                    aria-expanded={open}
                    onClick={() => setOpenId(open ? null : note.id)}
                  >
                    <span className="history-time">{clock(note.durationSeconds)}</span>
                    <span
                      className={`history-text${note.state === "failed" ? " history-text--error" : ""}`}
                    >
                      {note.title}
                    </span>
                    {note.state === "transcribing" && <span className="step-note">writing it up…</span>}
                    {note.state === "recorded" && <span className="step-note">not transcribed</span>}
                    <svg className="history-chevron" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
                      <path d="m8 5 7 7-7 7" />
                    </svg>
                  </button>

                  {open && (
                    <div className="history-detail" style={{ paddingLeft: 84 }}>
                      {note.speakers.length > 0 && (
                        <p className="step-detail">
                          <span>Voices</span>
                          <em>{note.speakers.join(", ")}</em>
                        </p>
                      )}
                      <p className="step-detail">
                        <span>Transcribed by</span>
                        <em>{note.engine === "local" ? "Apple, on this Mac" : note.engine || "—"}</em>
                      </p>
                      {note.error && <p className="drop-error">{note.error}</p>}
                      {note.summary && (
                        <>
                          <p className="step-title" style={{ marginTop: 14 }}>Summary</p>
                          <pre className="step-text">{note.summary}</pre>
                        </>
                      )}
                      {note.transcript && (
                        <>
                          <p className="step-title" style={{ marginTop: 14 }}>Transcript</p>
                          <pre className="job-transcript">{note.transcript}</pre>
                        </>
                      )}
                      <div className="job-actions" style={{ marginTop: 14, marginBottom: 0 }}>
                        {note.state === "ready" && !note.summary && (
                          <button className="btn" onClick={() => summarise(note.id)}>
                            Summarise
                          </button>
                        )}
                        {note.state !== "transcribing" && (
                          <button
                            className="btn"
                            onClick={async () => {
                              await window.zflow?.notetaker.meetings("transcribe", { id: note.id });
                              await refresh();
                            }}
                          >
                            {note.transcript ? "Transcribe again" : "Transcribe"}
                          </button>
                        )}
                        <button className="btn btn--danger" onClick={() => remove(note.id)}>
                          Delete recording
                        </button>
                      </div>
                    </div>
                  )}
                </div>
              );
            })}
          </div>
        </section>
      )}
    </>
  );
}
