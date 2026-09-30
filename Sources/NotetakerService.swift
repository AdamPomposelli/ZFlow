import AVFoundation
import Foundation

/// Turns a recorded meeting into a transcript with names against the lines.
///
/// Both tracks are transcribed separately and then interleaved by time. The
/// split does most of the work: your microphone is you by definition, so no
/// model has to guess that part. Diarization only has to separate the remote
/// voices from each other.
enum NotetakerService {
    struct Outcome {
        let segments: [TranscriptSegment]
        let transcript: String
        let speakers: [String]
        let engine: String
    }

    /// How much audio goes into one request.
    ///
    /// On-device is free, so windows stay short and the timings stay tight.
    /// A cloud provider is charged per request, so its windows are longer —
    /// coarser placement, but a meeting that does not cost a fortune.
    static func windowCeiling(for engine: TranscriptionEngine) -> Double {
        engine == .local ? 15 : 45
    }

    /// Transcribes one track into timed segments under a fixed speaker label.
    ///
    /// The track is cut on silence first. Neither engine gives timings fine
    /// enough to interleave two recordings with — the on-device analyzer
    /// returns one range covering everything it was fed at once, and a cloud
    /// provider returns none — so the cut is what tells us when each line was
    /// said, and it is the same answer for both.
    static func transcribeTrack(
        at url: URL,
        speaker: String,
        engine: TranscriptionEngine,
        languageCode: String?,
        cloudService: @escaping () throws -> TranscriptionService,
        /// Times where the speaker changes, so no window covers two of them.
        boundaries: [Double] = [],
        onProgress: @escaping (Double) -> Void
    ) async throws -> [TranscriptSegment] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let duration = FileTranscriptionService.audioDurationSeconds(of: url)
        guard duration > 0.2 else { return [] }

        let energies = try FileTranscriptionService.energies(from: url)
        let batches = AudioSegmentationCore.plan(
            energies: energies,
            boundaries: boundaries,
            maximumSeconds: windowCeiling(for: engine)
        )
        guard !batches.isEmpty else { return [] }

        var segments: [TranscriptSegment] = []
        for (index, window) in batches.enumerated() {
            try Task.checkCancellation()
            let text: String
            switch engine {
            case .local:
                guard #available(macOS 26.0, *) else { throw FileTranscriptionError.localUnavailable }
                text = try await FileTranscriptionService.transcribeWindowLocally(
                    url: url,
                    window: window,
                    languageCode: languageCode
                )
            case .cloud:
                let clip = FileManager.default.temporaryDirectory
                    .appendingPathComponent("zflow-window-\(UUID().uuidString).wav")
                defer { try? FileManager.default.removeItem(at: clip) }
                try FileTranscriptionService.writeWindowWAV(from: url, window: window, to: clip)
                text = try await cloudService().transcribe(fileURL: clip)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            onProgress(Double(index + 1) / Double(batches.count))
            guard !text.isEmpty else { continue }
            segments.append(TranscriptSegment(
                speaker: speaker,
                text: text,
                start: window.start,
                end: window.end
            ))
        }
        return segments
    }

    /// How much audio an engine actually processed: only the windows that
    /// held speech, not the silence between them.
    static func transcribedSeconds(_ segments: [TranscriptSegment]) -> Double {
        segments.reduce(0) { $0 + max(0, $1.end - $1.start) }
    }

    /// Builds the finished conversation from both tracks and, when it is
    /// available, the diarization of the remote one.
    static func assemble(
        mic: [TranscriptSegment],
        remote: [TranscriptSegment],
        remoteTurns: [SpeakerTurn],
        engine: TranscriptionEngine
    ) -> Outcome {
        let named = TimedTranscriptCore.labelling(
            remote,
            with: remoteTurns,
            naming: NotetakerCore.speakerName(forDiarizedIndex:)
        )
        // Anyone not wearing headphones records the far side twice. The
        // microphone copy goes; the system track is the better recording of a
        // remote voice, and the one carrying the speaker names.
        let ownVoice = TimedTranscriptCore.removingEcho(from: mic, heardAlsoIn: named)
        let merged = TimedTranscriptCore.merge([ownVoice, named])
        return Outcome(
            segments: merged,
            transcript: TimedTranscriptCore.render(merged),
            speakers: TimedTranscriptCore.speakers(in: merged),
            engine: engine.rawValue
        )
    }
}
