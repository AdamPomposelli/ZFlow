import { utilityProcess } from "electron";
import { createWriteStream, promises as fs } from "node:fs";
import { pipeline } from "node:stream/promises";
import path from "node:path";
import { Readable } from "node:stream";

/**
 * Telling the remote voices apart.
 *
 * Your own side needs no model — it is whatever your microphone heard. This
 * only ever runs on the other track, which is why it can be this small: a
 * segmentation model to find turn boundaries, an embedding model to say which
 * turns are the same person, and clustering to group them.
 *
 * The models are fetched on first use rather than shipped. They are 35 MB
 * together, they are only needed by people who record meetings, and a download
 * someone can see and decline is better than 35 MB in everyone's app.
 */
export interface SpeakerTurn {
  speaker: number;
  start: number;
  end: number;
}

const MODELS = [
  {
    file: "segmentation.onnx",
    url: "https://huggingface.co/csukuangfj/sherpa-onnx-pyannote-segmentation-3-0/resolve/main/model.onnx",
    bytes: 5_905_324,
  },
  {
    file: "embedding.onnx",
    url: "https://huggingface.co/csukuangfj/speaker-embedding-models/resolve/main/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx",
    bytes: 28_281_138,
  },
] as const;

let modelDirectory: string | null = null;

export function configureModelDirectory(directory: string): void {
  modelDirectory = directory;
}

function pathFor(file: string): string {
  if (!modelDirectory) throw new Error("Model directory not configured");
  return path.join(modelDirectory, file);
}

export async function modelsReady(): Promise<boolean> {
  try {
    for (const model of MODELS) {
      const stat = await fs.stat(pathFor(model.file));
      // A half-finished download is not a model; re-fetch rather than hand a
      // truncated file to the runtime and get a crash instead of an error.
      if (stat.size < model.bytes * 0.9) return false;
    }
    return true;
  } catch {
    return false;
  }
}

export async function downloadModels(
  onProgress: (fraction: number) => void
): Promise<{ ok: boolean; error?: string }> {
  if (!modelDirectory) return { ok: false, error: "No place to put the models." };
  try {
    await fs.mkdir(modelDirectory, { recursive: true });
    const total = MODELS.reduce((sum, model) => sum + model.bytes, 0);
    let done = 0;
    for (const model of MODELS) {
      const target = pathFor(model.file);
      try {
        const stat = await fs.stat(target);
        if (stat.size >= model.bytes * 0.9) {
          done += model.bytes;
          onProgress(done / total);
          continue;
        }
      } catch {
        // Not there yet.
      }
      const response = await fetch(model.url);
      if (!response.ok || !response.body) {
        return { ok: false, error: `Could not download ${model.file} (${response.status}).` };
      }
      // Written to a temporary name first, so an interrupted download is never
      // mistaken for a finished one.
      const partial = `${target}.partial`;
      await pipeline(Readable.fromWeb(response.body as never), createWriteStream(partial));
      await fs.rename(partial, target);
      done += model.bytes;
      onProgress(done / total);
    }
    return { ok: true };
  } catch (error) {
    return { ok: false, error: error instanceof Error ? error.message : String(error) };
  }
}

/**
 * Speaker turns in one mono 16 kHz WAV.
 *
 * Handed to a utility process: inference on a long meeting would otherwise
 * freeze the window for as long as it takes, and loading 33 MB of shared
 * library into the main process is a cost that should fall only on people who
 * record meetings.
 */
export async function diarize(wavPath: string): Promise<SpeakerTurn[]> {
  if (!(await modelsReady())) return [];
  const worker = utilityProcess.fork(path.join(__dirname, "diarize-worker.js"), [], {
    serviceName: "ZFlow speaker models",
  });

  return new Promise<SpeakerTurn[]>((resolve) => {
    let settled = false;
    const finish = (turns: SpeakerTurn[]) => {
      if (settled) return;
      settled = true;
      worker.kill();
      resolve(turns);
    };
    worker.on("message", (message: { ok: boolean; turns?: SpeakerTurn[] }) => {
      finish(message?.ok && message.turns ? message.turns : []);
    });
    // A crash in the ONNX runtime costs the speaker names, not the transcript.
    worker.on("exit", () => finish([]));
    worker.postMessage({
      wavPath,
      segmentationModel: pathFor("segmentation.onnx"),
      embeddingModel: pathFor("embedding.onnx"),
      sherpaPath: sherpaModulePath(),
      threshold: 0.5,
    });
  });
}

/**
 * Where the native module sits, resolved rather than required, because the
 * worker loads it and the main process must never map it.
 */
function sherpaModulePath(): string {
  return path.join(__dirname, "..", "node_modules", "sherpa-onnx-node");
}
