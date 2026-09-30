import Foundation

enum MeetingSummaryCoreTests {
    static func run() {
        shortMeetingsAreNotWorthSummarising()
        aLongTranscriptKeepsItsEnding()
        trimmingNeverStartsMidLine()
        thePromptCarriesTheCastAndTheRules()
        theRulesCannotBeMistakenForSubjectMatter()
        boilerplateIsStripped()
        blankLineRunsCollapse()
    }

    private static func shortMeetingsAreNotWorthSummarising() {
        TestSupport.expect(
            !MeetingSummaryCore.isWorthSummarising("[0:00] You: hello. [0:02] Them: hi"),
            "two lines are not a meeting"
        )
        let long = (0..<50).map { "word\($0)" }.joined(separator: " ")
        TestSupport.expect(MeetingSummaryCore.isWorthSummarising(long), "fifty words is enough")
    }

    /// Decisions and next steps come at the end, so it is the beginning that
    /// goes when something has to.
    private static func aLongTranscriptKeepsItsEnding() {
        let lines = (0..<500).map { "[0:00] You: line \($0)" }.joined(separator: "\n")
        let trimmed = MeetingSummaryCore.trimmed(lines, limit: 400)
        TestSupport.expect(trimmed.contains("line 499"), "the end is kept")
        TestSupport.expect(!trimmed.contains("line 0\n"), "the beginning is dropped")
        TestSupport.expect(trimmed.hasPrefix("[earlier in the meeting"), "and it says so")
    }

    /// A half sentence with no speaker in front reads as if someone said it.
    private static func trimmingNeverStartsMidLine() {
        let lines = "[0:00] You: first line\n[0:05] Them: second line\n[0:09] You: third line"
        let trimmed = MeetingSummaryCore.trimmed(lines, limit: 30)
        let body = trimmed.split(separator: "\n").dropFirst().joined()
        TestSupport.expect(body.hasPrefix("["), "got \(body)")
    }

    private static func thePromptCarriesTheCastAndTheRules() {
        let prompt = MeetingSummaryCore.prompt(
            transcript: "[0:00] You: hello",
            speakers: ["You", "Speaker 1"]
        )
        TestSupport.expect(prompt.contains("You, Speaker 1"), "the cast is named")
        TestSupport.expect(prompt.contains("Never invent"), "the contract is stated")
        TestSupport.expect(prompt.contains("[0:00] You: hello"), "the transcript is included")

        let anonymous = MeetingSummaryCore.prompt(transcript: "x", speakers: [])
        TestSupport.expect(anonymous.contains("unknown"), "an empty cast still reads")
    }

    /// A small model asked under a heading called "Hard contract" writes that
    /// the meeting was about a hard contract. The instructions must not read
    /// as topics.
    private static func theRulesCannotBeMistakenForSubjectMatter() {
        let prompt = MeetingSummaryCore.prompt(transcript: "[0:00] You: hello", speakers: [])
        TestSupport.expect(
            !prompt.lowercased().contains("hard contract"),
            "the instructions must not name a thing a meeting could be about"
        )
        TestSupport.expect(
            prompt.contains("instructions to you, not part of the meeting"),
            "the prompt says which half is which"
        )
    }

    private static func boilerplateIsStripped() {
        TestSupport.expectEqual(
            MeetingSummaryCore.cleaned("Here is the summary:\n\nThey agreed."),
            "They agreed."
        )
        TestSupport.expectEqual(MeetingSummaryCore.cleaned("  They agreed.  "), "They agreed.")
    }

    private static func blankLineRunsCollapse() {
        TestSupport.expectEqual(
            MeetingSummaryCore.cleaned("A\n\n\n\n\nB"),
            "A\n\nB"
        )
    }
}
