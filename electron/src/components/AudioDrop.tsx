import React from "react";
import { Icon } from "../icons";

export interface TranscriptionJob {
  id: string;
  fileName: string;
  state: "running" | "finished" | "failed";
  engine: string;
  audioSeconds: number;
  progress?: number;
  transcript?: string;
  error?: string;
}

function duration(seconds: number): string {
  if (!seconds) return "";
  const minutes = Math.floor(seconds / 60);
  const rest = Math.round(seconds % 60);
  return minutes ? `${minutes}:${String(rest).padStart(2, "0")}` : `${rest}s`;
}

/**
 * Drop a recording in, get the words out.
 *
 * It goes through whichever engine is already configured, so a dropped file is
 * treated exactly like a dictation: same model, same language, same choice
 * about whether anything leaves the machine. The file itself is never read by
 * this window — only its path is handed over, and the app opens it.
 */
export function AudioDrop() {
  const [job, setJob] = React.useState<TranscriptionJob | null>(null);
  const [error, setError] = React.useState<string | null>(null);
  const [over, setOver] = React.useState(false);
  const [copied, setCopied] = React.useState(false);
  const chooser = React.useRef<HTMLInputElement>(null);

  // Polling stops the moment the job leaves "running", and is torn down if the
  // page goes away mid-transcription.
  React.useEffect(() => {
    if (!job || job.state !== "running") return;
    let cancelled = false;
    const timer = setInterval(async () => {
      const next = (await window.zflow?.transcribeFileStatus(job.id)) as TranscriptionJob | null;
      if (cancelled || !next) return;
      setJob(next);
    }, 700);
    return () => {
      cancelled = true;
      clearInterval(timer);
    };
  }, [job?.id, job?.state]);

  const start = async (file: File) => {
    setError(null);
    setCopied(false);
    const path = window.zflow?.filePath(file);
    if (!path) {
      setError("ZFlow could not work out where that file is.");
      return;
    }
    const result = (await window.zflow?.transcribeFile(path)) as
      | { ok: boolean; error?: string; job?: TranscriptionJob }
      | undefined;
    if (!result?.ok || !result.job) {
      setError(result?.error ?? "ZFlow is not running.");
      setJob(null);
      return;
    }
    setJob(result.job);
  };

  const onDrop = (event: React.DragEvent) => {
    event.preventDefault();
    setOver(false);
    const file = event.dataTransfer.files[0];
    if (file) start(file);
  };

  const copy = async () => {
    if (!job?.transcript) return;
    await navigator.clipboard.writeText(job.transcript);
    setCopied(true);
    window.setTimeout(() => setCopied(false), 2000);
  };

  const running = job?.state === "running";

  return (
    <>
      <p className="page-lede">
        Drop a recording in and ZFlow writes down what was said. It uses the engine you already
        chose in Voice &amp; AI — on this Mac, or your provider — so a dropped file goes exactly
        where your dictations go, and nowhere else.
      </p>

      <div
        className={`drop${over ? " drop--over" : ""}${running ? " drop--busy" : ""}`}
        onDragOver={(event) => {
          event.preventDefault();
          setOver(true);
        }}
        onDragLeave={() => setOver(false)}
        onDrop={onDrop}
      >
        <span className="drop-glyph">
          <Icon.download />
        </span>
        <p className="drop-title">Drop an audio file here</p>
        <p className="drop-sub">WAV, MP3, M4A, FLAC, or the audio from an MP4.</p>
        <button className="btn" onClick={() => chooser.current?.click()} disabled={running}>
          Choose a file
        </button>
        <input
          ref={chooser}
          type="file"
          accept=".wav,.wave,.mp3,.m4a,.aac,.caf,.aif,.aiff,.flac,.mp4,.m4v,.mov"
          hidden
          onChange={(event) => {
            const file = event.target.files?.[0];
            if (file) start(file);
            event.target.value = "";
          }}
        />
      </div>

      {error && <p className="drop-error">{error}</p>}

      {job && (
        <section className="job">
          <div className="job-head">
            <span className="job-name">{job.fileName}</span>
            {job.audioSeconds > 0 && <span className="job-meta">{duration(job.audioSeconds)}</span>}
            <span className={`badge badge--${job.engine === "local" ? "local" : "cloud"}`}>
              {job.engine === "local" ? "On this Mac" : "Cloud"}
            </span>
          </div>

          {running && (
            <>
              <div className="job-bar">
                <span style={{ width: `${Math.round((job.progress ?? 0) * 100)}%` }} />
              </div>
              <p className="job-status">
                Reading the audio… {Math.round((job.progress ?? 0) * 100)}%
              </p>
            </>
          )}

          {job.state === "failed" && <p className="drop-error">{job.error}</p>}

          {job.state === "finished" && job.transcript && (
            <>
              <div className="job-actions">
                <button className="btn" onClick={copy}>
                  {copied ? "Copied" : "Copy transcript"}
                </button>
              </div>
              <pre className="job-transcript">{job.transcript}</pre>
            </>
          )}
        </section>
      )}
    </>
  );
}
