import Foundation
import AVFoundation

enum AudioUploadEncoderTests {
    static func run() {
        testFLACIsLosslessAndSmaller()
        testShortRecordingsAreNotReencoded()
        testWavFormatIsLeftUntouched()
        testUnreadableInputFallsBackToTheOriginal()
    }

    /// Writes a synthetic tone. Never a real recording: test fixtures must not
    /// contain user audio.
    private static func makeToneWAV(seconds: Double) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zflow-test-\(UUID().uuidString).wav")
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ) else { return nil }

        let frames = AVAudioFrameCount(seconds * 16_000)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buffer.int16ChannelData else { return nil }
        buffer.frameLength = frames
        for frame in 0..<Int(frames) {
            let phase = Double(frame) / 16_000 * 2 * Double.pi * 440
            channel[0][frame] = Int16(sin(phase) * 8_000)
        }

        guard let file = try? AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        ) else { return nil }
        try? file.write(from: buffer)
        return url
    }

    private static func samples(of url: URL) -> [Int16]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else { return nil }
        try? file.read(into: buffer)
        guard let channel = buffer.floatChannelData else { return nil }
        return (0..<Int(buffer.frameLength)).map { Int16(max(-32_768, min(32_767, channel[0][$0] * 32_768))) }
    }

    private static func testFLACIsLosslessAndSmaller() {
        guard let source = makeToneWAV(seconds: 4) else {
            TestSupport.expect(false, "Could not write the test recording")
            return
        }
        defer { try? FileManager.default.removeItem(at: source) }

        let upload = AudioUploadEncoder.prepareUpload(
            fileURL: source,
            preferredFormat: .flac,
            audioDurationSeconds: 4
        )
        defer { upload.cleanUp() }

        TestSupport.expectEqual(upload.format, .flac)
        TestSupport.expect(upload.isTemporary, "An encoded upload should be a temporary file")
        TestSupport.expectEqual(upload.fileURL.pathExtension, "flac")

        let originalSize = AudioUploadEncoder.fileSize(of: source)
        let encodedSize = AudioUploadEncoder.fileSize(of: upload.fileURL)
        TestSupport.expect(encodedSize > 0, "The encoded file should not be empty")
        TestSupport.expect(
            encodedSize < originalSize,
            "FLAC should be smaller than PCM (\(encodedSize) vs \(originalSize))"
        )

        // The whole reason for choosing FLAC over a lossy codec: the provider
        // must receive the samples that were recorded, so accuracy cannot move.
        guard let before = samples(of: source), let after = samples(of: upload.fileURL) else {
            TestSupport.expect(false, "Could not read back the samples")
            return
        }
        TestSupport.expectEqual(before.count, after.count)
        var maxDelta = 0
        for (lhs, rhs) in zip(before, after) {
            maxDelta = max(maxDelta, abs(Int(lhs) - Int(rhs)))
        }
        TestSupport.expect(maxDelta <= 1, "FLAC must round-trip losslessly, saw delta \(maxDelta)")
    }

    private static func testShortRecordingsAreNotReencoded() {
        guard let source = makeToneWAV(seconds: 0.5) else {
            TestSupport.expect(false, "Could not write the test recording")
            return
        }
        defer { try? FileManager.default.removeItem(at: source) }

        // Below the threshold the encode costs more than the upload saves.
        let upload = AudioUploadEncoder.prepareUpload(
            fileURL: source,
            preferredFormat: .flac,
            audioDurationSeconds: 0.5
        )
        defer { upload.cleanUp() }

        TestSupport.expectEqual(upload.format, .wav)
        TestSupport.expectEqual(upload.fileURL, source)
        TestSupport.expect(!upload.isTemporary, "The original must not be marked for deletion")
    }

    private static func testWavFormatIsLeftUntouched() {
        guard let source = makeToneWAV(seconds: 3) else {
            TestSupport.expect(false, "Could not write the test recording")
            return
        }
        defer { try? FileManager.default.removeItem(at: source) }

        let upload = AudioUploadEncoder.prepareUpload(
            fileURL: source,
            preferredFormat: .wav,
            audioDurationSeconds: 3
        )
        TestSupport.expectEqual(upload.format, .wav)
        TestSupport.expectEqual(upload.fileURL, source)
        TestSupport.expect(!upload.isTemporary, "The original must not be marked for deletion")
    }

    private static func testUnreadableInputFallsBackToTheOriginal() {
        // A failed encode must never cost the user their dictation.
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("zflow-test-not-audio-\(UUID().uuidString).wav")
        try? Data("not audio".utf8).write(to: bogus)
        defer { try? FileManager.default.removeItem(at: bogus) }

        let upload = AudioUploadEncoder.prepareUpload(
            fileURL: bogus,
            preferredFormat: .flac,
            audioDurationSeconds: 5
        )
        TestSupport.expectEqual(upload.format, .wav)
        TestSupport.expectEqual(upload.fileURL, bogus)
        TestSupport.expect(!upload.isTemporary, "A failed encode must not mark the original for deletion")
    }
}
