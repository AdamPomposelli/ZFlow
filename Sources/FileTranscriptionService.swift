import AVFoundation
import Foundation

enum FileTranscriptionError: LocalizedError {
    case unreadable(String)
    case noSpeech
    case localUnavailable

    var errorDescription: String? {
        switch self {
        case .unreadable(let detail):
            return "ZFlow could not read that audio: \(detail)"
        case .noSpeech:
            return "No speech was found in that file."
        case .localUnavailable:
            return "On-device transcription needs macOS 26. Switch Speech to text to a cloud provider in Voice & AI, or update macOS."
        }
    }
}

/// Transcribes an audio file the user dropped in.
///
/// It goes through whichever engine is already configured, so a dropped
/// recording is treated exactly like a dictation: the same model, the same
/// language, the same choice about whether anything leaves the machine.
enum FileTranscriptionService {
    /// The rate the on-device analyzer is fed at. Speech models work at 16 kHz;
    /// anything higher is resampled away inside them regardless.
    static let localSampleRate: Double = 16_000

    static func audioDurationSeconds(of url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        guard file.fileFormat.sampleRate > 0 else { return 0 }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    /// Reads a whole file as mono 16-bit PCM, in chunks.
    ///
    /// Chunked on purpose: an hour of 48 kHz stereo float is well over a
    /// gigabyte if read in one go, and a meeting recording is exactly the case
    /// this feature exists for.
    static func readPCM16(
        from url: URL,
        sampleRate: Double = localSampleRate,
        onChunk: (Data, Double) throws -> Void
    ) throws {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw FileTranscriptionError.unreadable(error.localizedDescription)
        }

        let inputFormat = file.processingFormat
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw FileTranscriptionError.unreadable("unsupported audio format")
        }

        let framesPerChunk = AVAudioFrameCount(inputFormat.sampleRate * 2)
        guard let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: framesPerChunk) else {
            throw FileTranscriptionError.unreadable("could not allocate an audio buffer")
        }
        let ratio = sampleRate / inputFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(framesPerChunk) * ratio) + 2048

        let totalFrames = Double(file.length)
        while file.framePosition < file.length {
            input.frameLength = 0
            do {
                try file.read(into: input, frameCount: framesPerChunk)
            } catch {
                throw FileTranscriptionError.unreadable(error.localizedDescription)
            }
            guard input.frameLength > 0 else { break }

            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
                throw FileTranscriptionError.unreadable("could not allocate an output buffer")
            }
            var conversionError: NSError?
            var delivered = false
            converter.convert(to: output, error: &conversionError) { _, status in
                if delivered {
                    status.pointee = .noDataNow
                    return nil
                }
                delivered = true
                status.pointee = .haveData
                return input
            }
            if let conversionError {
                throw FileTranscriptionError.unreadable(conversionError.localizedDescription)
            }
            guard output.frameLength > 0, let channel = output.int16ChannelData else { continue }

            let byteCount = Int(output.frameLength) * MemoryLayout<Int16>.size
            let data = Data(bytes: channel[0], count: byteCount)
            let progress = totalFrames > 0 ? Double(file.framePosition) / totalFrames : 0
            try onChunk(data, min(progress, 1))
        }
    }

    /// Frame energies for a whole file, read streaming so an hour of audio
    /// never sits in memory at once.
    static func energies(from url: URL, sampleRate: Double = localSampleRate) throws -> [Double] {
        var all: [Double] = []
        try readPCM16(from: url, sampleRate: sampleRate) { chunk, _ in
            all.append(contentsOf: AudioSegmentationCore.frameEnergies(
                pcm16: chunk,
                sampleRate: sampleRate
            ))
        }
        return all
    }

    /// Just the samples inside one window.
    static func readPCM16(
        from url: URL,
        window: VoiceWindow,
        sampleRate: Double = localSampleRate
    ) throws -> Data {
        var collected = Data()
        var elapsed = 0.0
        let bytesPerSecond = sampleRate * 2
        try readPCM16(from: url, sampleRate: sampleRate) { chunk, _ in
            let chunkSeconds = Double(chunk.count) / bytesPerSecond
            let chunkEnd = elapsed + chunkSeconds
            defer { elapsed = chunkEnd }
            guard chunkEnd > window.start, elapsed < window.end else { return }
            let from = max(0, Int((window.start - elapsed) * bytesPerSecond)) & ~1
            let to = min(chunk.count, Int((window.end - elapsed) * bytesPerSecond) + 1) & ~1
            guard to > from else { return }
            collected.append(chunk.subdata(in: from..<to))
        }
        return collected
    }

    /// Transcribes one window of a file, on-device.
    @available(macOS 26.0, *)
    static func transcribeWindowLocally(
        url: URL,
        window: VoiceWindow,
        languageCode: String?
    ) async throws -> String {
        let pcm = try readPCM16(from: url, window: window)
        guard pcm.count > Int(localSampleRate) / 5 else { return "" }
        let session = LocalSpeechTranscriber(languageCode: languageCode, inputSampleRate: localSampleRate)
        try session.start()
        session.appendPCM16(pcm)
        let text = try await session.commitAndAwaitFinal()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Writes one window out as a WAV, for an engine that takes a file.
    static func writeWindowWAV(
        from url: URL,
        window: VoiceWindow,
        to destination: URL,
        sampleRate: Double = localSampleRate
    ) throws {
        let pcm = try readPCM16(from: url, window: window)
        guard !pcm.isEmpty else { throw FileTranscriptionError.noSpeech }
        var header = Data()
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        header.append(contentsOf: Array("RIFF".utf8))
        append32(UInt32(36 + pcm.count))
        header.append(contentsOf: Array("WAVEfmt ".utf8))
        append32(16)
        append16(1)
        append16(1)
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate) * 2)
        append16(2)
        append16(16)
        header.append(contentsOf: Array("data".utf8))
        append32(UInt32(pcm.count))
        try (header + pcm).write(to: destination, options: .atomic)
    }

    /// The same work, keeping the time each utterance covers.
    ///
    /// Two recordings of the same meeting can only be interleaved into a
    /// conversation if both sides say when they were speaking.
    @available(macOS 26.0, *)
    static func transcribeLocallyTimed(
        url: URL,
        languageCode: String?,
        onProgress: @escaping (Double) -> Void
    ) async throws -> [LocalSpeechTranscriber.TimedText] {
        let session = LocalSpeechTranscriber(languageCode: languageCode, inputSampleRate: localSampleRate)
        try session.start()
        do {
            try readPCM16(from: url) { chunk, progress in
                session.appendPCM16(chunk)
                onProgress(progress * 0.95)
            }
        } catch {
            session.cancel()
            throw error
        }
        _ = try await session.commitAndAwaitFinal()
        onProgress(1)
        return session.finalSegments
    }

    /// Runs the file through Apple's on-device transcriber.
    @available(macOS 26.0, *)
    static func transcribeLocally(
        url: URL,
        languageCode: String?,
        onProgress: @escaping (Double) -> Void
    ) async throws -> String {
        let session = LocalSpeechTranscriber(languageCode: languageCode, inputSampleRate: localSampleRate)
        try session.start()
        do {
            try readPCM16(from: url) { chunk, progress in
                session.appendPCM16(chunk)
                onProgress(progress * 0.95)
            }
        } catch {
            session.cancel()
            throw error
        }
        let transcript = try await session.commitAndAwaitFinal()
        onProgress(1)
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FileTranscriptionError.noSpeech }
        return trimmed
    }
}
