import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import path from "node:path";

/**
 * Talks to the running ZFlow app.
 *
 * The app publishes a loopback-only HTTP endpoint and writes its port and a
 * per-launch token to a 0600 handshake file. Reads and writes go through the
 * same published properties the native settings use, so a change here takes
 * effect immediately rather than at the app's next launch.
 */
export interface Handshake {
  port: number;
  token: string;
}

const CANDIDATE_APP_NAMES = ["ZFlow Dev", "ZFlow"];

function handshakePath(appName: string): string {
  return path.join(homedir(), "Library", "Application Support", appName, "ui-bridge.json");
}

export async function readHandshake(): Promise<{ handshake: Handshake; appName: string } | null> {
  for (const appName of CANDIDATE_APP_NAMES) {
    try {
      const raw = await readFile(handshakePath(appName), "utf8");
      const handshake = JSON.parse(raw) as Handshake;
      if (handshake.port && handshake.token) return { handshake, appName };
    } catch {
      // Not this bundle, or the app is not running.
    }
  }
  return null;
}

async function call<T>(
  handshake: Handshake,
  route: string,
  body?: unknown
): Promise<T> {
  const response = await fetch(`http://127.0.0.1:${handshake.port}${route}`, {
    method: body === undefined ? "GET" : "POST",
    headers: {
      Authorization: `Bearer ${handshake.token}`,
      "Content-Type": "application/json",
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (!response.ok) throw new Error(`${route} failed: ${response.status}`);
  return (await response.json()) as T;
}

export async function readSettings(): Promise<Record<string, unknown>> {
  const found = await readHandshake();
  if (!found) return {};
  return call<Record<string, unknown>>(found.handshake, "/settings");
}

export async function writeSetting(key: string, value: unknown): Promise<boolean> {
  const found = await readHandshake();
  if (!found) return false;
  const result = await call<{ ok: boolean }>(found.handshake, "/settings", { key, value });
  return result.ok;
}

export async function readHistory(): Promise<unknown[]> {
  const found = await readHandshake();
  if (!found) return [];
  const result = await call<{ items: unknown[] }>(found.handshake, "/history");
  return result.items;
}

export async function deleteHistoryEntry(id: string): Promise<boolean> {
  const found = await readHandshake();
  if (!found) return false;
  try {
    const result = await call<{ ok: boolean }>(found.handshake, "/history/delete", { id });
    return result.ok;
  } catch {
    return false;
  }
}

export async function readDictionary(): Promise<unknown[]> {
  const found = await readHandshake();
  if (!found) return [];
  const result = await call<{ items: unknown[] }>(found.handshake, "/dictionary");
  return result.items;
}

export async function mutateDictionary(payload: Record<string, unknown>): Promise<boolean> {
  const found = await readHandshake();
  if (!found) return false;
  const result = await call<{ ok: boolean }>(found.handshake, "/dictionary", payload);
  return result.ok;
}

export async function readMicrophones(): Promise<unknown[]> {
  const found = await readHandshake();
  if (!found) return [];
  const result = await call<{ items: unknown[] }>(found.handshake, "/microphones");
  return result.items;
}

/**
 * The prompt text the app falls back to when a prompt field is left empty.
 * The front end shows this rather than an empty box, so what is actually being
 * sent is visible and editable instead of implied.
 */
export async function readDefaults(): Promise<Record<string, string>> {
  const found = await readHandshake();
  if (!found) return {};
  return call<Record<string, string>>(found.handshake, "/defaults");
}

/**
 * The dictation languages the *currently selected* transcription engine can
 * handle — Apple's downloaded and downloadable locales, or the provider's
 * list — so the picker never offers a language that would be rejected.
 */
export async function readLanguages(): Promise<Record<string, unknown>> {
  const found = await readHandshake();
  if (!found) return {};
  return call<Record<string, unknown>>(found.handshake, "/languages");
}

/**
 * One run's screenshot, fetched only when its row is expanded. These are
 * pictures of the user's screen: they stay on this machine, they travel over
 * the same loopback socket as everything else, and they are never part of the
 * history listing that polls in the background.
 */
export async function readScreenshot(id: string): Promise<string | null> {
  const found = await readHandshake();
  if (!found) return null;
  try {
    const result = await call<{ dataURL: string }>(
      found.handshake,
      `/screenshot?id=${encodeURIComponent(id)}`
    );
    return result.dataURL ?? null;
  } catch {
    // 404 is the ordinary answer for a run that had no screenshot.
    return null;
  }
}

/** Local usage counts for the Insights page. Aggregates only. */
export async function readInsights(): Promise<Record<string, unknown>> {
  const found = await readHandshake();
  if (!found) return {};
  return call<Record<string, unknown>>(found.handshake, "/insights");
}

export interface PermissionItem {
  access: string;
  title: string;
  purpose: string;
  state: "granted" | "missing" | "not_needed";
}

export interface PermissionReport {
  items: PermissionItem[];
  allGranted: boolean;
  outstanding: number;
}

export async function readPermissions(): Promise<PermissionReport> {
  const found = await readHandshake();
  if (!found) return { items: [], allGranted: false, outstanding: 0 };
  return call<PermissionReport>(found.handshake, "/permissions");
}

/**
 * Asks the app to request one permission. The app owns this: the dialog has
 * to be attributed to the process that actually needs the access, and that is
 * never this window.
 */
export async function requestPermission(access: string): Promise<boolean> {
  const found = await readHandshake();
  if (!found) return false;
  const result = await call<{ ok: boolean }>(found.handshake, "/permissions/request", { access });
  return result.ok;
}

export async function resetInsights(): Promise<boolean> {
  const found = await readHandshake();
  if (!found) return false;
  const result = await call<{ ok: boolean }>(found.handshake, "/insights/reset", {});
  return result.ok;
}

/**
 * Starts transcribing a dropped file and answers at once with a job to poll.
 * The file never travels through here — only its path — and the app reads it
 * with whichever engine is configured.
 */
export async function startFileTranscription(
  filePath: string
): Promise<Record<string, unknown>> {
  const found = await readHandshake();
  if (!found) return { ok: false, error: "ZFlow is not running." };
  return call<Record<string, unknown>>(found.handshake, "/transcribe-file", { path: filePath });
}

export async function fileTranscriptionStatus(
  id: string
): Promise<Record<string, unknown> | null> {
  const found = await readHandshake();
  if (!found) return null;
  try {
    return await call<Record<string, unknown>>(
      found.handshake,
      `/transcribe-file?id=${encodeURIComponent(id)}`
    );
  } catch {
    return null;
  }
}

/** Everything to do with recorded meetings, by action name. */
export async function meetings(
  action: string,
  body: Record<string, unknown> = {}
): Promise<Record<string, unknown>> {
  const found = await readHandshake();
  if (!found) return { ok: false, error: "ZFlow is not running." };
  return call<Record<string, unknown>>(found.handshake, "/meetings", { action, ...body });
}

/** Asks the app itself to quit. */
export async function quitApp(): Promise<boolean> {
  const found = await readHandshake();
  if (!found) return false;
  const result = await call<{ ok: boolean }>(found.handshake, "/quit", {});
  return result.ok;
}

export async function status(): Promise<{ connected: boolean; appName: string | null }> {
  const found = await readHandshake();
  return { connected: found !== null, appName: found?.appName ?? null };
}
