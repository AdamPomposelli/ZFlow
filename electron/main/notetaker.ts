import { desktopCapturer, shell, systemPreferences } from "electron";
import { WavWriter } from "./wav-writer";
import { meetings } from "./settings-bridge";

/**
 * Recording a meeting: two files being written at once, for as long as it
 * lasts.
 *
 * The microphone and everything the machine plays go to separate tracks,
 * because that split is what tells you apart from everyone else later without
 * any model having to guess.
 */
interface Recording {
  id: string;
  mic: WavWriter;
  system: WavWriter;
  startedAt: number;
}

const active = new Map<string, Recording>();

export type CaptureStatus = "granted" | "denied" | "not-determined" | "restricted" | "unknown";

/**
 * Whether macOS will let us hear the far side of a call.
 *
 * System audio is gated behind Screen Recording on macOS, and the permission
 * belongs to this window's bundle, not to ZFlow itself — so it has to be asked
 * for here, and only when a recording is about to start.
 */
export async function captureStatus(): Promise<{
  screen: CaptureStatus;
  microphone: CaptureStatus;
  sources: number;
}> {
  const screen = systemPreferences.getMediaAccessStatus("screen") as CaptureStatus;
  const microphone = systemPreferences.getMediaAccessStatus("microphone") as CaptureStatus;
  let sources = 0;
  if (screen === "granted") {
    try {
      sources = (await desktopCapturer.getSources({ types: ["screen"] })).length;
    } catch {
      sources = 0;
    }
  }
  return { screen, microphone, sources };
}

/**
 * Asks for what is missing.
 *
 * Touching desktopCapturer is what makes macOS show its own dialog the first
 * time. Once it has been refused, only System Settings can undo that, so that
 * is where we send people rather than asking again into the void.
 */
export async function requestCapture(): Promise<{
  screen: CaptureStatus;
  microphone: CaptureStatus;
  openedSettings: boolean;
}> {
  const before = await captureStatus();
  let openedSettings = false;

  if (before.microphone === "not-determined") {
    await systemPreferences.askForMediaAccess("microphone");
  }
  if (before.screen !== "granted") {
    // macOS has no "not-determined" for screen capture: never asked and
    // refused both read as denied. So the attempt is made regardless — it is
    // what shows the system dialog the first time — and System Settings is
    // only opened if that changed nothing, which means it really was refused.
    try {
      await desktopCapturer.getSources({ types: ["screen"] });
    } catch {
      // Expected while the permission is missing.
    }
    if ((systemPreferences.getMediaAccessStatus("screen") as CaptureStatus) !== "granted") {
      await shell.openExternal(
        "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
      );
      openedSettings = true;
    }
  }

  const after = await captureStatus();
  return { screen: after.screen, microphone: after.microphone, openedSettings };
}

export async function startRecording(): Promise<
  { ok: true; id: string; systemTrackPath: string } | { ok: false; error: string }
> {
  const created = (await meetings("create")) as {
    ok?: boolean;
    error?: string;
    note?: { id: string };
    micTrackPath?: string;
    systemTrackPath?: string;
  };
  if (!created?.ok || !created.note || !created.micTrackPath || !created.systemTrackPath) {
    return { ok: false, error: created?.error ?? "ZFlow is not running." };
  }

  const mic = new WavWriter(created.micTrackPath);
  const system = new WavWriter(created.systemTrackPath);
  await mic.open();
  await system.open();
  active.set(created.note.id, { id: created.note.id, mic, system, startedAt: Date.now() });
  return { ok: true, id: created.note.id, systemTrackPath: created.systemTrackPath };
}

export function writeChunk(id: string, track: "mic" | "system", chunk: ArrayBuffer): void {
  const recording = active.get(id);
  if (!recording) return;
  recording[track].write(Buffer.from(chunk));
}

export async function stopRecording(
  id: string
): Promise<{ ok: boolean; durationSeconds: number }> {
  const recording = active.get(id);
  if (!recording) return { ok: false, durationSeconds: 0 };
  active.delete(id);

  const [micSeconds, systemSeconds] = await Promise.all([
    recording.mic.close(),
    recording.system.close(),
  ]);
  const durationSeconds = Math.max(micSeconds, systemSeconds);
  await meetings("finish", { id, durationSeconds });
  return { ok: true, durationSeconds };
}

/** How long the recording in progress has been running, for the UI's clock. */
export function recordingSeconds(id: string): number {
  const recording = active.get(id);
  if (!recording) return 0;
  return Math.max(recording.mic.seconds, recording.system.seconds);
}
