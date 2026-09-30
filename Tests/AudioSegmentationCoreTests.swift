import Foundation

enum AudioSegmentationCoreTests {
    // Helpers are used by the extension below too.
    static func run() {
        silenceHasNoWindows()
        speechBetweenSilenceIsFound()
        aPauseInsideASentenceDoesNotSplitIt()
        aRealGapSplitsTurns()
        blipsAreDiscarded()
        theThresholdFollowsTheRecording()
        energiesAreReadFromRealSamples()
        batchingRespectsItsCeiling()
        batchingKeepsDistantWindowsApart()
        windowsAreCutWhereTheSpeakerChanges()
        batchingNeverSpansASpeakerChange()
        aPlanCutsAndGathersInOneGo()
    }

    static func frames(_ pattern: [(level: Double, seconds: Double)]) -> [Double] {
        pattern.flatMap { part in
            Array(repeating: part.level, count: Int(part.seconds / AudioSegmentationCore.frameSeconds))
        }
    }

    private static func silenceHasNoWindows() {
        TestSupport.expectEqual(AudioSegmentationCore.windows(energies: frames([(0.0005, 5)])).count, 0)
        TestSupport.expectEqual(AudioSegmentationCore.windows(energies: []).count, 0)
    }

    private static func speechBetweenSilenceIsFound() {
        let energies = frames([(0.001, 2), (0.2, 3), (0.001, 2)])
        let windows = AudioSegmentationCore.windows(energies: energies, threshold: 0.05)
        TestSupport.expectEqual(windows.count, 1)
        // Padded outwards, so a word is not clipped at either end.
        TestSupport.expect(windows[0].start < 2 && windows[0].start > 1.7, "start \(windows[0].start)")
        TestSupport.expect(windows[0].end > 5 && windows[0].end < 5.3, "end \(windows[0].end)")
    }

    /// Breathing between clauses is not a turn boundary.
    private static func aPauseInsideASentenceDoesNotSplitIt() {
        let energies = frames([(0.2, 1), (0.001, 0.3), (0.2, 1)])
        let windows = AudioSegmentationCore.windows(energies: energies, threshold: 0.05)
        TestSupport.expectEqual(windows.count, 1)
    }

    private static func aRealGapSplitsTurns() {
        let energies = frames([(0.2, 1), (0.001, 2), (0.2, 1)])
        let windows = AudioSegmentationCore.windows(energies: energies, threshold: 0.05)
        TestSupport.expectEqual(windows.count, 2)
        TestSupport.expect(windows[1].start > 2.8, "second window starts at \(windows[1].start)")
    }

    private static func blipsAreDiscarded() {
        let energies = frames([(0.001, 1), (0.3, 0.1), (0.001, 1)])
        TestSupport.expectEqual(
            AudioSegmentationCore.windows(energies: energies, threshold: 0.05).count,
            0
        )
    }

    /// A quiet room and a noisy call have nothing in common, so the level
    /// comes from the recording rather than from a constant.
    private static func theThresholdFollowsTheRecording() {
        let quiet = frames([(0.0005, 4), (0.05, 2)])
        let noisy = frames([(0.03, 4), (0.4, 2)])
        let quietLevel = AudioSegmentationCore.noiseThreshold(quiet)
        let noisyLevel = AudioSegmentationCore.noiseThreshold(noisy)
        TestSupport.expect(noisyLevel > quietLevel, "\(noisyLevel) should exceed \(quietLevel)")
        TestSupport.expect(quietLevel >= 0.004, "never below the absolute floor")
        // Speech in each recording still reads as speech.
        TestSupport.expect(0.05 > quietLevel, "quiet speech is above its own threshold")
        TestSupport.expect(0.4 > noisyLevel, "loud speech is above its own threshold")
    }

    private static func energiesAreReadFromRealSamples() {
        var loud = Data()
        for _ in 0..<16_000 {
            var sample = Int16(20_000)
            withUnsafeBytes(of: &sample) { loud.append(contentsOf: $0) }
        }
        let energies = AudioSegmentationCore.frameEnergies(pcm16: loud, sampleRate: 16_000)
        TestSupport.expectEqual(energies.count, 50)
        TestSupport.expect(energies[0] > 0.5 && energies[0] < 0.7, "got \(energies[0])")

        let silent = Data(repeating: 0, count: 32_000)
        let quiet = AudioSegmentationCore.frameEnergies(pcm16: silent, sampleRate: 16_000)
        TestSupport.expect(quiet.allSatisfy { $0 == 0 }, "silence reads as zero")
    }

    /// One request per utterance would be accurate and unaffordable.
    private static func batchingRespectsItsCeiling() {
        let windows = (0..<10).map { VoiceWindow(start: Double($0) * 5, end: Double($0) * 5 + 4.5) }
        let batches = AudioSegmentationCore.batching(windows, maximumSeconds: 12)
        TestSupport.expect(batches.count > 1, "ten windows do not fit in one batch")
        for batch in batches {
            TestSupport.expect(batch.duration <= 12.01, "batch of \(batch.duration)s exceeds the ceiling")
        }
        TestSupport.expectEqual(batches.first?.start, 0)
    }

    private static func batchingKeepsDistantWindowsApart() {
        let windows = [VoiceWindow(start: 0, end: 2), VoiceWindow(start: 60, end: 62)]
        TestSupport.expectEqual(AudioSegmentationCore.batching(windows, maximumSeconds: 120).count, 2)
    }
}

extension AudioSegmentationCoreTests {
    /// Otherwise a window covering two people is credited to whichever of them
    /// talked longest, and a three-way call comes back as one person.
    static func windowsAreCutWhereTheSpeakerChanges() {
        let cut = AudioSegmentationCore.splitting(
            [VoiceWindow(start: 0, end: 20)],
            at: [8, 14]
        )
        TestSupport.expectEqual(cut.count, 3)
        TestSupport.expectEqual(cut.map(\.start), [0, 8, 14])
        TestSupport.expectEqual(cut.map(\.end), [8, 14, 20])

        // Boundaries outside the window change nothing.
        TestSupport.expectEqual(
            AudioSegmentationCore.splitting([VoiceWindow(start: 10, end: 12)], at: [2, 40]).count,
            1
        )
        // A sliver either side of a boundary is not an utterance.
        TestSupport.expectEqual(
            AudioSegmentationCore.splitting([VoiceWindow(start: 0, end: 5)], at: [4.95]).count,
            1
        )
    }

    static func batchingNeverSpansASpeakerChange() {
        let windows = [VoiceWindow(start: 0, end: 8), VoiceWindow(start: 8.5, end: 14)]
        TestSupport.expectEqual(
            AudioSegmentationCore.batching(windows, maximumSeconds: 30).count,
            1
        )
        TestSupport.expectEqual(
            AudioSegmentationCore.batching(windows, maximumSeconds: 30, notCrossing: [8.2]).count,
            2
        )
    }

    static func aPlanCutsAndGathersInOneGo() {
        let energies = frames([(0.001, 1), (0.2, 12), (0.001, 1)])
        let plain = AudioSegmentationCore.plan(energies: energies, maximumSeconds: 30)
        TestSupport.expectEqual(plain.count, 1)

        let split = AudioSegmentationCore.plan(
            energies: energies,
            boundaries: [5, 9],
            maximumSeconds: 30
        )
        TestSupport.expectEqual(split.count, 3)
    }
}
