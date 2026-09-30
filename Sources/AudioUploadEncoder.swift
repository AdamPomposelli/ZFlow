import Foundation
import AudioToolbox
import AVFoundation
import os.log

private let uploadEncoderLog = OSLog(
    subsystem: "com.zippy.zflow",
    category: "AudioUploadEncoder"
)

/// Compresses the recording before it is uploaded.
///
/// ZFlow records 16 kHz mono PCM16, which is ~32 KB per second of speech and
/// ~43 KB once base64 encoded for providers that take JSON. That whole payload
/// is sent after the user releases the key, so every kilobyte is time the user
/// spends waiting with nothing on screen. FLAC is lossless — the provider
/// receives bit-identical samples, so accuracy cannot change — and is accepted
/// by both Groq and ZenMux.
enum AudioUploadEncoder {
    /// Container formats the upload can use, in the app's own vocabulary.
    enum Format: String, CaseIterable {
        /// Send the recording untouched.
        case wav
        /// Lossless compression. Same samples, roughly 2.5x fewer bytes.
        case flac

        var fileExtension: String {
            switch self {
            case .wav: return "wav"
            case .flac: return "flac"
            }
        }
    }

    /// Recordings shorter than this are not worth re-encoding: the payload is
    /// already small, and the encode would cost more time than the upload saves.
    static let minimumDurationSecondsToEncode: TimeInterval = 1.5

    struct EncodedUpload {
        let fileURL: URL
        let format: Format
        /// True when a temporary file was written that the caller must delete.
        let isTemporary: Bool

        func cleanUp() {
            guard isTemporary else { return }
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    /// Returns a FLAC copy of `fileURL`, or the original when encoding is not
    /// worth it, not supported by the provider, or fails. Never throws: a
    /// compression failure must degrade to the original upload rather than lose
    /// the user's dictation.
    static func prepareUpload(
        fileURL: URL,
        preferredFormat: Format,
        audioDurationSeconds: TimeInterval?
    ) -> EncodedUpload {
        let original = EncodedUpload(fileURL: fileURL, format: .wav, isTemporary: false)

        guard preferredFormat == .flac else { return original }
        if let audioDurationSeconds, audioDurationSeconds < minimumDurationSecondsToEncode {
            return original
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("zflow-upload-\(UUID().uuidString)")
            .appendingPathExtension(Format.flac.fileExtension)

        do {
            try encodeToFLAC(source: fileURL, destination: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            os_log(
                .info,
                log: uploadEncoderLog,
                "FLAC encode failed, uploading the original recording: %{public}@",
                error.localizedDescription
            )
            return original
        }

        // A codec that somehow made the payload bigger is not worth using.
        let originalSize = fileSize(of: fileURL)
        let encodedSize = fileSize(of: destination)
        guard encodedSize > 0, originalSize <= 0 || encodedSize < originalSize else {
            try? FileManager.default.removeItem(at: destination)
            return original
        }

        return EncodedUpload(fileURL: destination, format: .flac, isTemporary: true)
    }

    enum EncodingError: LocalizedError {
        case openFailed(OSStatus)
        case configurationFailed(OSStatus)
        case conversionFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .openFailed(let status): return "Could not open the recording (OSStatus \(status))"
            case .configurationFailed(let status): return "Could not configure the encoder (OSStatus \(status))"
            case .conversionFailed(let status): return "Could not encode the recording (OSStatus \(status))"
            }
        }
    }

    /// AVAudioFile cannot write FLAC, so this goes through ExtAudioFile, which
    /// is the same AudioToolbox path `afconvert` uses.
    static func encodeToFLAC(source: URL, destination: URL) throws {
        var sourceFile: ExtAudioFileRef?
        var status = ExtAudioFileOpenURL(source as CFURL, &sourceFile)
        guard status == noErr, let sourceFile else { throw EncodingError.openFailed(status) }
        defer { ExtAudioFileDispose(sourceFile) }

        // Read the source's native layout so the encoder matches its rate and
        // channel count rather than resampling.
        var sourceFormat = AudioStreamBasicDescription()
        var sourceFormatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = ExtAudioFileGetProperty(
            sourceFile,
            kExtAudioFileProperty_FileDataFormat,
            &sourceFormatSize,
            &sourceFormat
        )
        guard status == noErr else { throw EncodingError.configurationFailed(status) }

        let sampleRate = sourceFormat.mSampleRate > 0 ? sourceFormat.mSampleRate : 16_000
        let channels = sourceFormat.mChannelsPerFrame > 0 ? sourceFormat.mChannelsPerFrame : 1

        var flacFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatFLAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 0,
            mBytesPerFrame: 0,
            mChannelsPerFrame: channels,
            // FLAC is integer-only; this is the sample depth it stores.
            mBitsPerChannel: 16,
            mReserved: 0
        )

        var destinationFile: ExtAudioFileRef?
        status = ExtAudioFileCreateWithURL(
            destination as CFURL,
            kAudioFileFLACType,
            &flacFormat,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &destinationFile
        )
        guard status == noErr, let destinationFile else { throw EncodingError.openFailed(status) }
        defer { ExtAudioFileDispose(destinationFile) }

        // Both ends exchange packed PCM16, so AudioToolbox does the decode on
        // one side and the FLAC encode on the other.
        var clientFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2 * channels,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2 * channels,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        let clientFormatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

        status = ExtAudioFileSetProperty(
            sourceFile,
            kExtAudioFileProperty_ClientDataFormat,
            clientFormatSize,
            &clientFormat
        )
        guard status == noErr else { throw EncodingError.configurationFailed(status) }

        status = ExtAudioFileSetProperty(
            destinationFile,
            kExtAudioFileProperty_ClientDataFormat,
            clientFormatSize,
            &clientFormat
        )
        guard status == noErr else { throw EncodingError.configurationFailed(status) }

        let framesPerRead: UInt32 = 8192
        let bytesPerFrame = Int(clientFormat.mBytesPerFrame)
        var buffer = [UInt8](repeating: 0, count: Int(framesPerRead) * bytesPerFrame)

        while true {
            var frameCount = framesPerRead
            var didFinish = false

            try buffer.withUnsafeMutableBytes { rawBuffer in
                var bufferList = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: channels,
                        mDataByteSize: UInt32(rawBuffer.count),
                        mData: rawBuffer.baseAddress
                    )
                )

                let readStatus = ExtAudioFileRead(sourceFile, &frameCount, &bufferList)
                guard readStatus == noErr else { throw EncodingError.conversionFailed(readStatus) }

                guard frameCount > 0 else {
                    didFinish = true
                    return
                }

                bufferList.mBuffers.mDataByteSize = frameCount * clientFormat.mBytesPerFrame
                let writeStatus = ExtAudioFileWrite(destinationFile, frameCount, &bufferList)
                guard writeStatus == noErr else { throw EncodingError.conversionFailed(writeStatus) }
            }

            if didFinish { break }
        }
    }

    static func fileSize(of url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
