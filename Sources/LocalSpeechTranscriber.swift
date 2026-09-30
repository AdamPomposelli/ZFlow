import Foundation
import AVFoundation
import Speech
import os.log

private let localSpeechLog = OSLog(
    subsystem: "com.zippy.zflow",
    category: "LocalSpeechTranscription"
)

/// On-device transcription through Apple's SpeechAnalyzer.
///
/// Audio is fed in while the user is still speaking, so by the time the key is
/// released only the tail is left to process. Nothing leaves the machine: no
/// API key, no per-hour cost, and no upload to wait on. Requires macOS 26,
/// where `SpeechAnalyzer` and `SpeechTranscriber` live; callers must check
/// `isSupported` before constructing one.
@available(macOS 26.0, *)
final class LocalSpeechTranscriber: StreamingTranscriptionSession, @unchecked Sendable {
    /// Whether this machine can transcribe locally at all. False on older
    /// macOS and on hardware where the model is unavailable.
    static var isSupported: Bool {
        SpeechTranscriber.isAvailable
    }

    /// Resolves a ZFlow language code onto a locale the on-device model
    /// actually has. An empty code means auto-detect, which SpeechAnalyzer does
    /// not do: it transcribes one locale at a time, so the system language is
    /// the closest honest equivalent.
    static func resolveLocale(forLanguageCode code: String?) async -> Locale? {
        let trimmed = code?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let requested = trimmed.isEmpty ? Locale.current : Locale(identifier: trimmed)
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: requested) {
            return match
        }
        // Fall back to any installed locale rather than failing outright.
        if let installed = await SpeechTranscriber.installedLocales.first {
            return installed
        }
        return await SpeechTranscriber.supportedLocales.first
    }

    static func installedLocaleIdentifiers() async -> [String] {
        await SpeechTranscriber.installedLocales.map(\.identifier)
    }

    static func supportedLocaleIdentifiers() async -> [String] {
        await SpeechTranscriber.supportedLocales.map(\.identifier)
    }

    /// Why the on-device model could not be made ready, when it could not.
    enum AssetPreparation: Equatable {
        case ready
        /// This Mac has no model for the locale at all.
        case unsupported(String)
        /// It could have one, and fetching it did not work.
        case downloadFailed(String)
    }

    /// Makes the on-device model for `locale` usable, downloading it if needed.
    ///
    /// The question is whether the model is on this disk — nothing else. See
    /// `SpeechAssetGateCore` for why `AssetInventory.status` alone cannot
    /// answer it: the status follows a reservation Apple's speech service
    /// forgets whenever macOS restarts it, and treating that as "no model"
    /// failed every dictation until relaunch.
    ///
    /// An app may hold only a handful of locales at once — five — so a locale
    /// is reserved before a download, and kept reserved while in use so macOS
    /// does not reclaim it.
    @discardableResult
    static func prepareAssets(for locale: Locale) async -> AssetPreparation {
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)

        switch await gate(for: locale, transcriber: transcriber) {
        case .transcribe:
            // Keep the slot, but never make a dictation wait on it or fail on
            // it: the model is already here, and the analyzer runs without a
            // reservation.
            Task.detached(priority: .utility) { _ = await reserveIfNeeded(locale) }
            return .ready
        case .unsupported:
            return .unsupported("macOS has no speech model for \(locale.identifier) on this Mac.")
        case .download:
            break
        }

        if let problem = await reserveIfNeeded(locale) { return .downloadFailed(problem) }

        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        } catch {
            os_log(
                .default,
                log: localSpeechLog,
                "Could not install the on-device model for %{public}@: %{public}@",
                locale.identifier,
                error.localizedDescription
            )
            return .downloadFailed("Downloading the \(locale.identifier) model failed: \(error.localizedDescription)")
        }

        // Asked the same way as before the download: is it on disk now.
        return await gate(for: locale, transcriber: transcriber) == .transcribe
            ? .ready
            : .downloadFailed("The \(locale.identifier) model finished downloading, but macOS does not list it as installed.")
    }

    private static func gate(
        for locale: Locale,
        transcriber: SpeechTranscriber
    ) async -> SpeechAssetGateCore.Decision {
        let installed = await SpeechTranscriber.installedLocales.map(\.identifier)
        let status = await AssetInventory.status(forModules: [transcriber])
        return SpeechAssetGateCore.decision(
            locale: locale.identifier,
            installedLocales: installed,
            inventory: inventory(status)
        )
    }

    private static func inventory(_ status: AssetInventory.Status) -> SpeechAssetGateCore.Inventory {
        switch status {
        case .unsupported: return .unsupported
        case .supported: return .supported
        case .downloading: return .downloading
        case .installed: return .installed
        @unknown default: return .supported
        }
    }

    /// Claims one of the app's locale slots, making room if they are all taken.
    ///
    /// Releasing someone else's slot is safe: a released locale's assets stay
    /// on disk, and reserving it again later costs nothing. Refusing to
    /// transcribe because of a slot held by a language the user has not spoken
    /// in a month is not.
    private static func reserveIfNeeded(_ locale: Locale) async -> String? {
        let reserved = await AssetInventory.reservedLocales
        if reserved.contains(where: { $0.identifier == locale.identifier }) { return nil }

        do {
            try await AssetInventory.reserve(locale: locale)
            return nil
        } catch {
            guard let spareIdentifier = LocaleReservationCore.reservationToRelease(
                reserved: reserved.map(\.identifier),
                wanted: locale.identifier,
                keeping: Locale.current.identifier
            ), let spare = reserved.first(where: { $0.identifier == spareIdentifier }) else {
                return "Could not reserve \(locale.identifier): \(error.localizedDescription)"
            }
            await AssetInventory.release(reservedLocale: spare)
            os_log(
                .default,
                log: localSpeechLog,
                "Released the reserved locale %{public}@ to make room for %{public}@",
                spare.identifier,
                locale.identifier
            )
            do {
                try await AssetInventory.reserve(locale: locale)
                return nil
            } catch {
                return "Could not reserve \(locale.identifier) even after freeing \(spare.identifier): \(error.localizedDescription)"
            }
        }
    }

    /// Each case says what actually went wrong. "No on-device model" is kept
    /// for the one case where that is true: it used to be shown for a model
    /// that was installed and working, which sent people to check their
    /// language downloads for a problem that was never there.
    enum LocalTranscriptionError: LocalizedError, ShortDisplayableError {
        case unsupportedOnThisMac
        case modelUnavailable(String, String)
        case modelDownloadFailed(String, String)
        case analyzerFailed(String)
        case audioConversionFailed

        var errorDescription: String? {
            switch self {
            case .unsupportedOnThisMac:
                return "On-device transcription needs macOS 26 or later on supported hardware."
            case .modelUnavailable(let locale, let reason):
                return "There is no on-device speech model for \(locale). \(reason)"
            case .modelDownloadFailed(let locale, let reason):
                return "The on-device speech model for \(locale) could not be downloaded. \(reason)"
            case .analyzerFailed(let reason):
                return "Apple's on-device transcriber did not start. \(reason)"
            case .audioConversionFailed:
                return "The recorded audio could not be converted for the on-device model."
            }
        }

        var shortDisplayMessage: String {
            switch self {
            case .unsupportedOnThisMac: return "On-device transcription needs macOS 26"
            case .modelUnavailable(let locale, _): return "No on-device model for \(locale)"
            case .modelDownloadFailed(let locale, _): return "Could not download the \(locale) model"
            case .analyzerFailed: return "On-device transcription did not start"
            case .audioConversionFailed: return "Could not prepare audio for on-device transcription"
            }
        }
    }

    /// ZFlow's language code ("fr", "en", or empty for the system default).
    /// Resolved to a locale the model actually ships only once the analyzer
    /// starts, because that lookup is async and recording must not wait on it.
    private let languageCode: String?
    private let inputSampleRate: Double

    private let stateQueue = DispatchQueue(label: "com.zippy.zflow.localspeech.state")
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    private var collectTask: Task<Void, Never>?
    private var startTask: Task<Void, Error>?
    private var finalText = ""
    /// Final results with the times they cover, kept so a recording can be
    /// turned into a conversation rather than a wall of text. Only finals: a
    /// volatile result is a guess that has not settled and its range moves.
    struct TimedText: Equatable {
        let text: String
        let start: Double
        let end: Double
    }
    private var timedSegments: [TimedText] = []
    var finalSegments: [TimedText] { stateQueue.sync { timedSegments } }

    private var volatileText = ""
    private var didFinish = false
    /// Audio that arrived before the analyzer finished starting. Dropping it
    /// would silently lose the first word of every dictation.
    private var pendingAudio: [Data] = []

    /// Published on the main queue as the transcript grows, for a live readout.
    var onPartialUpdate: ((String) -> Void)?

    init(languageCode: String?, inputSampleRate: Double) {
        self.languageCode = languageCode
        self.inputSampleRate = inputSampleRate
    }

    /// Begins analysis. Returns immediately; audio appended before the analyzer
    /// is ready is buffered and replayed once it is.
    func start() throws {
        let startTask = Task { [weak self] in
            guard let self else { return }
            try await self.startAnalyzer()
        }
        stateQueue.sync { self.startTask = startTask }
    }

    private func startAnalyzer() async throws {
        guard Self.isSupported else { throw LocalTranscriptionError.unsupportedOnThisMac }

        // "fr" has to become "fr_FR" — the model ships specific locales, and
        // SpeechTranscriber does not do the widening itself.
        guard let locale = await Self.resolveLocale(forLanguageCode: languageCode) else {
            throw LocalTranscriptionError.modelUnavailable(
                languageCode ?? "the system language",
                "No supported locale matched it."
            )
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        switch await Self.prepareAssets(for: locale) {
        case .ready:
            break
        case .unsupported(let reason):
            throw LocalTranscriptionError.modelUnavailable(locale.identifier, reason)
        case .downloadFailed(let reason):
            throw LocalTranscriptionError.modelDownloadFailed(locale.identifier, reason)
        }
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]
        ) else {
            throw LocalTranscriptionError.analyzerFailed("macOS offered no audio format the model can read.")
        }

        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: inputSampleRate,
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: inputFormat, to: analyzerFormat) else {
            throw LocalTranscriptionError.audioConversionFailed
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()

        let collectTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    var snapshot = ""
                    let range = result.range
                    self.stateQueue.sync {
                        if result.isFinal {
                            self.finalText += text
                            self.volatileText = ""
                            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                self.timedSegments.append(TimedText(
                                    text: trimmed,
                                    start: range.start.seconds,
                                    end: range.end.seconds
                                ))
                            }
                        } else {
                            self.volatileText = text
                        }
                        snapshot = self.finalText + self.volatileText
                    }
                    if let onPartialUpdate = self.onPartialUpdate {
                        DispatchQueue.main.async { onPartialUpdate(snapshot) }
                    }
                }
            } catch {
                os_log(
                    .error,
                    log: localSpeechLog,
                    "On-device results stream ended: %{public}@",
                    error.localizedDescription
                )
            }
        }

        let queued: [Data] = stateQueue.sync {
            self.analyzer = analyzer
            self.transcriber = transcriber
            self.continuation = continuation
            self.converter = converter
            self.analyzerFormat = analyzerFormat
            self.collectTask = collectTask
            let queued = self.pendingAudio
            self.pendingAudio = []
            return queued
        }

        // The analyzer is the final judge of whether the model works, so its
        // own reason is what gets reported — not a guess made beforehand.
        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            throw LocalTranscriptionError.analyzerFailed(error.localizedDescription)
        }
        for data in queued {
            appendPCM16(data)
        }
    }

    /// Append 16-bit little-endian mono PCM at `inputSampleRate`.
    func appendPCM16(_ data: Data) {
        guard !data.isEmpty else { return }

        let ready: (AsyncStream<AnalyzerInput>.Continuation, AVAudioConverter, AVAudioFormat)? = stateQueue.sync {
            guard !didFinish else { return nil }
            guard let continuation, let converter, let analyzerFormat else {
                // Still starting up; keep the audio so no speech is lost.
                pendingAudio.append(data)
                return nil
            }
            return (continuation, converter, analyzerFormat)
        }
        guard let (continuation, converter, analyzerFormat) = ready else { return }

        guard let inputBuffer = Self.makeInputBuffer(from: data, sampleRate: inputSampleRate) else { return }

        let ratio = analyzerFormat.sampleRate / inputSampleRate
        let capacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 1024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else {
            return
        }

        var conversionError: NSError?
        var didSupply = false
        converter.convert(to: outputBuffer, error: &conversionError) { _, status in
            if didSupply {
                status.pointee = .noDataNow
                return nil
            }
            didSupply = true
            status.pointee = .haveData
            return inputBuffer
        }

        guard conversionError == nil, outputBuffer.frameLength > 0 else { return }
        continuation.yield(AnalyzerInput(buffer: outputBuffer))
    }

    private static func makeInputBuffer(from data: Data, sampleRate: Double) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        ) else { return nil }

        let frameCount = AVAudioFrameCount(data.count / 2)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channel = buffer.int16ChannelData else { return nil }
        buffer.frameLength = frameCount

        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: Int16.self).baseAddress else { return }
            channel[0].update(from: base, count: Int(frameCount))
        }
        return buffer
    }

    /// Closes the input and waits for the analyzer to finish the tail.
    func commitAndAwaitFinal() async throws -> String {
        let startTask: Task<Void, Error>? = stateQueue.sync { self.startTask }
        try await startTask?.value

        let parts: (SpeechAnalyzer?, AsyncStream<AnalyzerInput>.Continuation?, Task<Void, Never>?) = stateQueue.sync {
            guard !didFinish else { return (nil, nil, nil) }
            didFinish = true
            return (analyzer, continuation, collectTask)
        }

        parts.1?.finish()
        try await parts.0?.finalizeAndFinishThroughEndOfInput()
        await parts.2?.value

        return stateQueue.sync {
            let text = finalText.isEmpty ? volatileText : finalText
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func cancel() {
        let parts: (SpeechAnalyzer?, AsyncStream<AnalyzerInput>.Continuation?, Task<Void, Never>?, Task<Void, Error>?) = stateQueue.sync {
            guard !didFinish else { return (nil, nil, nil, nil) }
            didFinish = true
            return (analyzer, continuation, collectTask, startTask)
        }
        parts.3?.cancel()
        parts.1?.finish()
        parts.2?.cancel()
        if let analyzer = parts.0 {
            Task { await analyzer.cancelAndFinishNow() }
        }
    }
}
