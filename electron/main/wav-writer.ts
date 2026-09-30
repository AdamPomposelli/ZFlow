import { createWriteStream, promises as fs, type WriteStream } from "node:fs";

const HEADER_BYTES = 44;

/**
 * Writes 16-bit mono PCM to a WAV file as it arrives.
 *
 * Streamed rather than assembled in memory because a meeting is not a
 * dictation: an hour of it is over a hundred megabytes per track, and a crash
 * halfway through should leave an hour of audio on disk, not nothing. The
 * header is written up front with zero lengths and patched when the recording
 * stops, which is what makes that possible.
 */
export class WavWriter {
  private stream: WriteStream | null = null;
  private bytes = 0;

  constructor(
    readonly path: string,
    readonly sampleRate = 16000
  ) {}

  static header(sampleRate: number, dataBytes: number): Buffer {
    const header = Buffer.alloc(HEADER_BYTES);
    header.write("RIFF", 0);
    header.writeUInt32LE(36 + dataBytes, 4);
    header.write("WAVE", 8);
    header.write("fmt ", 12);
    header.writeUInt32LE(16, 16); // PCM chunk size
    header.writeUInt16LE(1, 20); // PCM
    header.writeUInt16LE(1, 22); // mono
    header.writeUInt32LE(sampleRate, 24);
    header.writeUInt32LE(sampleRate * 2, 28); // byte rate
    header.writeUInt16LE(2, 32); // block align
    header.writeUInt16LE(16, 34); // bits per sample
    header.write("data", 36);
    header.writeUInt32LE(dataBytes, 40);
    return header;
  }

  async open(): Promise<void> {
    this.stream = createWriteStream(this.path);
    this.bytes = 0;
    await new Promise<void>((resolve, reject) => {
      this.stream!.write(WavWriter.header(this.sampleRate, 0), (error) =>
        error ? reject(error) : resolve()
      );
    });
  }

  write(chunk: Buffer): void {
    if (!this.stream) return;
    this.stream.write(chunk);
    this.bytes += chunk.byteLength;
  }

  get seconds(): number {
    return this.bytes / (this.sampleRate * 2);
  }

  /** Closes the file and patches the header with the real lengths. */
  async close(): Promise<number> {
    if (!this.stream) return 0;
    const stream = this.stream;
    this.stream = null;
    await new Promise<void>((resolve) => stream.end(resolve));

    const handle = await fs.open(this.path, "r+");
    try {
      await handle.write(WavWriter.header(this.sampleRate, this.bytes), 0, HEADER_BYTES, 0);
    } finally {
      await handle.close();
    }
    return this.bytes / (this.sampleRate * 2);
  }
}
