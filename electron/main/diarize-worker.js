// Runs the speaker models away from the main process.
//
// Two reasons it is a separate process. Inference on an hour of audio takes
// long enough to freeze a window, and this loads 33 MB of shared library that
// an app which never records a meeting should never map. It also means a crash
// inside the ONNX runtime loses a transcript, not the app.
const fs = require("node:fs");

/**
 * Reads a 16-bit PCM WAV into plain JavaScript memory.
 *
 * Deliberately not sherpa's own readWave: that hands back an ArrayBuffer
 * backed by C memory, and Electron's V8 refuses those outright — "External
 * buffers are not allowed" — wherever the code runs.
 */
function readWav(file) {
  const buffer = fs.readFileSync(file);
  if (buffer.length < 12 || buffer.toString("ascii", 0, 4) !== "RIFF") {
    throw new Error("not a WAV file");
  }
  let offset = 12;
  let sampleRate = 16000;
  let bits = 16;
  let channels = 1;
  let data = null;
  while (offset + 8 <= buffer.length) {
    const id = buffer.toString("ascii", offset, offset + 4);
    const size = buffer.readUInt32LE(offset + 4);
    const body = offset + 8;
    if (id === "fmt ") {
      channels = buffer.readUInt16LE(body + 2);
      sampleRate = buffer.readUInt32LE(body + 4);
      bits = buffer.readUInt16LE(body + 14);
    } else if (id === "data") {
      data = buffer.subarray(body, Math.min(body + size, buffer.length));
    }
    offset = body + size + (size % 2);
  }
  if (!data || bits !== 16) throw new Error("expected 16-bit PCM");
  const frames = Math.floor(data.length / 2 / channels);
  const samples = new Float32Array(frames);
  for (let i = 0; i < frames; i++) {
    // Only the first channel: the tracks are mono, and a stray stereo file
    // should still diarize rather than fail.
    samples[i] = data.readInt16LE(i * channels * 2) / 32768;
  }
  return { samples, sampleRate };
}

process.parentPort.on("message", (event) => {
  const { wavPath, segmentationModel, embeddingModel, sherpaPath, threshold } = event.data;
  try {
    const sherpa = require(sherpaPath);
    const wave = readWav(wavPath);
    if (wave.samples.length < wave.sampleRate * 2) {
      process.parentPort.postMessage({ ok: true, turns: [] });
      return;
    }
    const diarizer = new sherpa.OfflineSpeakerDiarization({
      segmentation: { pyannote: { model: segmentationModel }, debug: false },
      embedding: { model: embeddingModel, debug: false },
      // How many people there are is not known in advance, so the threshold
      // decides: lower splits one voice into several, higher merges two.
      clustering: { numClusters: -1, threshold: threshold ?? 0.5 },
      minDurationOn: 0.3,
      minDurationOff: 0.5,
    });
    const segments = diarizer.process(wave.samples);
    process.parentPort.postMessage({
      ok: true,
      turns: segments.map((segment) => ({
        speaker: segment.speaker,
        start: segment.start,
        end: segment.end,
      })),
    });
  } catch (error) {
    process.parentPort.postMessage({ ok: false, error: String(error && error.message ? error.message : error) });
  }
});
