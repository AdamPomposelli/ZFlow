/**
 * Captures a meeting into two 16 kHz mono tracks.
 *
 * Raw PCM rather than a compressed container, deliberately: 16 kHz mono is
 * exactly what both speech engines want, AVFoundation opens a WAV without any
 * codec, and there is no encoder to ship or go wrong. It costs about 115 MB an
 * hour per track, which is the right trade for a file that has to be readable
 * by the rest of the app.
 */
export interface MeetingRecorder {
  id: string;
  /** Where the far side landed, for the speaker models to read afterwards. */
  systemTrackPath: string;
  stop: () => Promise<{ durationSeconds: number }>;
  levels: () => { mic: number; system: number };
  hasSystemAudio: boolean;
}

const SAMPLE_RATE = 16000;
const BLOCK = 4096;

function toInt16(input: Float32Array): ArrayBuffer {
  const out = new Int16Array(input.length);
  for (let i = 0; i < input.length; i++) {
    const clamped = Math.max(-1, Math.min(1, input[i]));
    out[i] = clamped < 0 ? clamped * 0x8000 : clamped * 0x7fff;
  }
  return out.buffer;
}

export async function startMeetingRecorder(): Promise<MeetingRecorder> {
  const bridge = window.zflow;
  if (!bridge) throw new Error("ZFlow is not running.");

  // The microphone first: it is the half that always works, and asking for
  // both at once makes a refusal of either look like a refusal of both.
  const micStream = await navigator.mediaDevices.getUserMedia({
    audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true },
  });

  let systemStream: MediaStream | null = null;
  try {
    const display = await navigator.mediaDevices.getDisplayMedia({ video: true, audio: true });
    // The picture is not wanted; only what was playing.
    display.getVideoTracks().forEach((track) => {
      track.stop();
      display.removeTrack(track);
    });
    systemStream = display.getAudioTracks().length ? display : null;
  } catch {
    systemStream = null;
  }

  const started = (await bridge.notetaker.start()) as
    | { ok: true; id: string; systemTrackPath: string }
    | { ok: false; error: string };
  if (!started.ok) {
    micStream.getTracks().forEach((t) => t.stop());
    systemStream?.getTracks().forEach((t) => t.stop());
    throw new Error(started.error);
  }

  const context = new AudioContext({ sampleRate: SAMPLE_RATE });
  // Nothing is played back: a microphone routed to the speakers is a howl,
  // and the system track would loop into itself.
  const mute = context.createGain();
  mute.gain.value = 0;
  mute.connect(context.destination);

  const levels = { mic: 0, system: 0 };
  const nodes: ScriptProcessorNode[] = [];
  // A decaying memory of how loud the far side is, so a gap between their
  // words does not open the gate for the tail of the same sentence.
  let farSide = 0;

  const tap = (stream: MediaStream, track: "mic" | "system") => {
    const source = context.createMediaStreamSource(stream);
    const processor = context.createScriptProcessor(BLOCK, 1, 1);
    processor.onaudioprocess = (event) => {
      const input = event.inputBuffer.getChannelData(0);
      let peak = 0;
      for (let i = 0; i < input.length; i++) {
        const value = Math.abs(input[i]);
        if (value > peak) peak = value;
      }
      levels[track] = peak;

      if (track === "system") {
        farSide = Math.max(peak, farSide * 0.7);
      }

      // Without headphones the microphone hears the speakers, and the far
      // side ends up transcribed twice — the second time as something you
      // said. While they are clearly louder than you are, your track is
      // silenced. Clearly, not merely: talking over someone has to still
      // come through, so the gate only closes when the microphone is well
      // below what is playing.
      const bleedingThrough =
        track === "mic" && farSide > 0.02 && peak < farSide * 0.55;
      const samples = bleedingThrough ? new Float32Array(input.length) : input;

      void bridge.notetaker.chunk(started.id, track, toInt16(samples));
    };
    source.connect(processor);
    processor.connect(mute);
    nodes.push(processor);
  };

  tap(micStream, "mic");
  if (systemStream) tap(systemStream, "system");

  return {
    id: started.id,
    systemTrackPath: started.systemTrackPath,
    hasSystemAudio: systemStream !== null,
    levels: () => ({ ...levels }),
    stop: async () => {
      nodes.forEach((node) => {
        node.onaudioprocess = null;
        node.disconnect();
      });
      micStream.getTracks().forEach((t) => t.stop());
      systemStream?.getTracks().forEach((t) => t.stop());
      await context.close();
      const result = (await bridge.notetaker.stop(started.id)) as {
        ok: boolean;
        durationSeconds: number;
      };
      return { durationSeconds: result?.durationSeconds ?? 0 };
    },
  };
}
