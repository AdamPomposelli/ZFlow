import Foundation

/// A stretch of a track where someone is speaking.
public struct VoiceWindow: Equatable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    public var duration: Double { end - start }
}

/// Finding the speech in a recording, so each utterance can be transcribed
/// with a time attached to it.
///
/// This exists because the time ranges the speech models hand back are not
/// fine enough to interleave two tracks with: fed a file at full speed, the
/// on-device analyzer will happily return one result covering thirteen
/// seconds, which puts a whole side of the conversation in one place. Cutting
/// on silence first gives every line a start we actually know, and it is the
/// same answer for a cloud provider, which returns no timings at all.
public enum AudioSegmentationCore {
    public static let frameSeconds = 0.02

    /// Root-mean-square level per frame, in 0...1.
    public static func frameEnergies(pcm16: Data, sampleRate: Double, frameSeconds: Double = frameSeconds) -> [Double] {
        let samplesPerFrame = max(1, Int(sampleRate * frameSeconds))
        let sampleCount = pcm16.count / 2
        guard sampleCount > 0 else { return [] }

        return pcm16.withUnsafeBytes { raw -> [Double] in
            let samples = raw.bindMemory(to: Int16.self)
            var energies: [Double] = []
            energies.reserveCapacity(sampleCount / samplesPerFrame + 1)
            var index = 0
            while index < sampleCount {
                let upper = min(index + samplesPerFrame, sampleCount)
                var sum = 0.0
                for position in index..<upper {
                    let value = Double(samples[position]) / 32768.0
                    sum += value * value
                }
                energies.append((sum / Double(upper - index)).squareRoot())
                index = upper
            }
            return energies
        }
    }

    /// The level below which a frame counts as silence.
    ///
    /// Taken from the recording rather than fixed, because a quiet room and a
    /// noisy call have nothing in common, and a fixed threshold gets one of
    /// them badly wrong.
    public static func noiseThreshold(_ energies: [Double], floor: Double = 0.004) -> Double {
        guard !energies.isEmpty else { return floor }
        let sorted = energies.sorted()
        let quiet = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.2))]
        let loud = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        // Well clear of the quiet floor, but never above a fifth of the loud
        // part, or ordinary speech gets cut off as silence.
        return max(floor, min(quiet * 4 + 0.002, loud * 0.2))
    }

    /// Speech windows, with short gaps bridged and blips discarded.
    public static func windows(
        energies: [Double],
        frameSeconds: Double = frameSeconds,
        threshold: Double? = nil,
        bridgingGap: Double = 0.45,
        minimumDuration: Double = 0.25,
        padding: Double = 0.15
    ) -> [VoiceWindow] {
        guard !energies.isEmpty else { return [] }
        let level = threshold ?? noiseThreshold(energies)

        var raw: [VoiceWindow] = []
        var runStart: Int?
        for (index, energy) in energies.enumerated() {
            if energy > level {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                raw.append(VoiceWindow(start: Double(start) * frameSeconds, end: Double(index) * frameSeconds))
                runStart = nil
            }
        }
        if let start = runStart {
            raw.append(VoiceWindow(
                start: Double(start) * frameSeconds,
                end: Double(energies.count) * frameSeconds
            ))
        }

        // Bridge the pauses inside a sentence; they are not turn boundaries.
        var bridged: [VoiceWindow] = []
        for window in raw {
            if var last = bridged.last, window.start - last.end <= bridgingGap {
                last.end = window.end
                bridged[bridged.count - 1] = last
            } else {
                bridged.append(window)
            }
        }

        let total = Double(energies.count) * frameSeconds
        return bridged
            .filter { $0.duration >= minimumDuration }
            .map { window in
                VoiceWindow(
                    start: max(0, window.start - padding),
                    end: min(total, window.end + padding)
                )
            }
    }

    /// Cuts windows wherever the speaker changes.
    ///
    /// Without this, a window can span two people and the whole thing gets
    /// attributed to whichever of them talked longest — which is exactly how a
    /// three-way conversation comes back as one person.
    public static func splitting(_ windows: [VoiceWindow], at boundaries: [Double]) -> [VoiceWindow] {
        guard !boundaries.isEmpty else { return windows }
        let sorted = boundaries.sorted()
        var result: [VoiceWindow] = []
        for window in windows {
            var cursor = window.start
            for boundary in sorted where boundary > window.start && boundary < window.end {
                result.append(VoiceWindow(start: cursor, end: boundary))
                cursor = boundary
            }
            result.append(VoiceWindow(start: cursor, end: window.end))
        }
        // A sliver either side of a boundary is not an utterance.
        return result.filter { $0.duration >= 0.2 }
    }

    /// Everything a track needs before it is transcribed: where the speech is,
    /// cut where the speaker changes, gathered into requests.
    public static func plan(
        energies: [Double],
        boundaries: [Double] = [],
        maximumSeconds: Double,
        frameSeconds: Double = frameSeconds
    ) -> [VoiceWindow] {
        let speech = windows(energies: energies, frameSeconds: frameSeconds)
        let cut = splitting(speech, at: boundaries)
        return batching(cut, maximumSeconds: maximumSeconds, notCrossing: boundaries)
    }

    /// Groups windows into batches no longer than `maximumSeconds`.
    ///
    /// One request per utterance would be accurate and unaffordable against a
    /// cloud provider; one request per track is cheap and places nothing in
    /// time. Batching is the honest middle: every batch still knows when it
    /// started.
    public static func batching(
        _ windows: [VoiceWindow],
        maximumSeconds: Double,
        joiningGapUnder gap: Double = 1.2,
        notCrossing boundaries: [Double] = []
    ) -> [VoiceWindow] {
        var batches: [VoiceWindow] = []
        for window in windows {
            guard var last = batches.last else {
                batches.append(window)
                continue
            }
            let wouldSpan = window.end - last.start
            let crossesSpeaker = boundaries.contains { $0 > last.start && $0 < window.end }
            if !crossesSpeaker, window.start - last.end <= gap, wouldSpan <= maximumSeconds {
                last.end = window.end
                batches[batches.count - 1] = last
            } else {
                batches.append(window)
            }
        }
        return batches
    }
}
