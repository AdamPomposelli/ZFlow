import Foundation

enum TimedTranscriptCoreTests {
    static func run() {
        tracksInterleaveByTime()
        neighbouringSegmentsFromOneSpeakerJoin()
        aLongSilenceDoesNotJoin()
        blankSegmentsAreDropped()
        aSegmentTakesTheSpeakerItOverlapsMost()
        aSegmentOverlappingNothingKeepsItsLabel()
        speakersAreRenumberedFromWhoSpokeFirst()
        speakerphoneBleedIsDropped()
        theSameWordsLaterAreNotEcho()
        yourOwnWordsSurviveAlongsideBleed()
        aDifferentSentenceAtTheSameMomentIsKept()
        renderingReadsAsAConversation()
        speakersComeOutInSpeakingOrder()
    }

    private static func seg(_ speaker: String, _ text: String, _ start: Double, _ end: Double) -> TranscriptSegment {
        TranscriptSegment(speaker: speaker, text: text, start: start, end: end)
    }

    private static func tracksInterleaveByTime() {
        let merged = TimedTranscriptCore.merge([
            [seg("You", "hello", 0, 1), seg("You", "and goodbye", 10, 11)],
            [seg("Them", "hi there", 2, 3)],
        ])
        TestSupport.expectEqual(merged.map(\.speaker), ["You", "Them", "You"])
        TestSupport.expectEqual(merged.map(\.text), ["hello", "hi there", "and goodbye"])
    }

    /// Otherwise a transcript reads as one line per breath.
    private static func neighbouringSegmentsFromOneSpeakerJoin() {
        let merged = TimedTranscriptCore.merge([[
            seg("You", "first part", 0, 2),
            seg("You", "second part", 2.4, 4),
        ]])
        TestSupport.expectEqual(merged.count, 1)
        TestSupport.expectEqual(merged.first?.text, "first part second part")
        TestSupport.expectEqual(merged.first?.end, 4)
    }

    private static func aLongSilenceDoesNotJoin() {
        let merged = TimedTranscriptCore.merge([[
            seg("You", "before", 0, 2),
            seg("You", "after", 30, 32),
        ]])
        TestSupport.expectEqual(merged.count, 2)
    }

    private static func blankSegmentsAreDropped() {
        let merged = TimedTranscriptCore.merge([[seg("You", "   ", 0, 1), seg("You", "real", 2, 3)]])
        TestSupport.expectEqual(merged.count, 1)
        TestSupport.expectEqual(merged.first?.text, "real")
    }

    /// A sentence that starts while someone else is finishing belongs to
    /// whoever said the bulk of it.
    private static func aSegmentTakesTheSpeakerItOverlapsMost() {
        let labelled = TimedTranscriptCore.labelling(
            [seg("Them", "mostly the second person", 4, 10)],
            with: [
                SpeakerTurn(speaker: 0, start: 0, end: 5),
                SpeakerTurn(speaker: 1, start: 5, end: 12),
            ],
            naming: { "Speaker \($0 + 1)" }
        )
        TestSupport.expectEqual(labelled.first?.speaker, "Speaker 2")
    }

    /// A wrong name is worse than a general one.
    private static func aSegmentOverlappingNothingKeepsItsLabel() {
        let labelled = TimedTranscriptCore.labelling(
            [seg("Them", "off on its own", 100, 105)],
            with: [SpeakerTurn(speaker: 0, start: 0, end: 5)],
            naming: { "Speaker \($0 + 1)" }
        )
        TestSupport.expectEqual(labelled.first?.speaker, "Them")

        let untouched = TimedTranscriptCore.labelling(
            [seg("Them", "no turns at all", 0, 5)],
            with: [],
            naming: { "Speaker \($0 + 1)" }
        )
        TestSupport.expectEqual(untouched.first?.speaker, "Them")
    }

    /// Clustering returns arbitrary ids, and "Speaker 4" opening a meeting
    /// with no Speaker 1 anywhere reads as a bug.
    private static func speakersAreRenumberedFromWhoSpokeFirst() {
        let renumbered = TimedTranscriptCore.renumberingByFirstAppearance([
            SpeakerTurn(speaker: 7, start: 0, end: 5),
            SpeakerTurn(speaker: 3, start: 6, end: 9),
            SpeakerTurn(speaker: 7, start: 10, end: 12),
        ])
        TestSupport.expectEqual(renumbered.map(\.speaker), [0, 1, 0])
        TestSupport.expectEqual(renumbered.map(\.start), [0, 6, 10])
        TestSupport.expectEqual(TimedTranscriptCore.renumberingByFirstAppearance([]).count, 0)
    }

    /// On speakerphone the far side is recorded twice, and the microphone copy
    /// says you said it.
    private static func speakerphoneBleedIsDropped() {
        let mine = [
            seg("You", "shall we start", 0, 2),
            seg("You", "merci beaucoup je suis la deuxieme personne", 8, 14),
        ]
        let theirs = [seg("Them", "Merci beaucoup, je suis la deuxième personne.", 8.2, 14.1)]
        let kept = TimedTranscriptCore.removingEcho(from: mine, heardAlsoIn: theirs)
        TestSupport.expectEqual(kept.count, 1)
        TestSupport.expectEqual(kept.first?.text, "shall we start")
    }

    /// The worst thing this can do is delete something you said. A window
    /// holding your sentence *and* the far side bleeding through is not a
    /// duplicate of the far side, and has to survive.
    private static func yourOwnWordsSurviveAlongsideBleed() {
        let mine = [seg(
            "You",
            "bonjour tout le monde on va commencer la reunion budgetaire merci beaucoup je suis la deuxieme personne",
            0,
            14
        )]
        let theirs = [seg("Them", "Merci beaucoup, je suis la deuxième personne.", 8, 14)]
        TestSupport.expectEqual(
            TimedTranscriptCore.removingEcho(from: mine, heardAlsoIn: theirs).count,
            1
        )
    }

    /// Someone repeating themselves a minute later is not an echo.
    private static func theSameWordsLaterAreNotEcho() {
        let mine = [seg("You", "let us look at the budget again", 100, 105)]
        let theirs = [seg("Them", "let us look at the budget again", 10, 15)]
        TestSupport.expectEqual(
            TimedTranscriptCore.removingEcho(from: mine, heardAlsoIn: theirs).count,
            1
        )
    }

    /// Two people talking at once is a conversation, not a duplicate.
    private static func aDifferentSentenceAtTheSameMomentIsKept() {
        let mine = [seg("You", "sorry could you repeat that", 8, 12)]
        let theirs = [seg("Them", "the quarterly figures are attached to the email", 8, 13)]
        TestSupport.expectEqual(
            TimedTranscriptCore.removingEcho(from: mine, heardAlsoIn: theirs).count,
            1
        )
    }

    private static func renderingReadsAsAConversation() {
        let text = TimedTranscriptCore.render([
            seg("You", "shall we start", 0, 2),
            seg("Speaker 1", "yes please", 65, 67),
        ])
        TestSupport.expectEqual(text, "[0:00] You: shall we start\n[1:05] Speaker 1: yes please")
        TestSupport.expectEqual(
            TimedTranscriptCore.render([seg("You", "no clock", 5, 6)], withTimes: false),
            "You: no clock"
        )
    }

    private static func speakersComeOutInSpeakingOrder() {
        let order = TimedTranscriptCore.speakers(in: [
            seg("Them", "a", 0, 1), seg("You", "b", 1, 2), seg("Them", "c", 2, 3),
        ])
        TestSupport.expectEqual(order, ["Them", "You"])
    }
}
