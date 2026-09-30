import Foundation

enum NotetakerCoreTests {
    static func run() {
        onlyIdentifiersWeCouldHaveMadeAreAccepted()
        aNoteStartsWithADatedTitle()
        aTitleIsSuggestedFromWhatWasSaid()
        aVeryLongOpeningIsClippedOnAWord()
        tooShortAnOpeningSuggestsNothing()
        speakersAreNumberedFromOne()
    }

    /// The id becomes a folder name, so anything that is not one of ours is
    /// refused rather than joined onto a path.
    private static func onlyIdentifiersWeCouldHaveMadeAreAccepted() {
        let id = NotetakerCore.newIdentifier()
        TestSupport.expect(NotetakerCore.isValidIdentifier(id), "a generated id is valid")
        for hostile in ["../../etc/passwd", "..", "", "a/b", "note 1", "%2e%2e"] {
            TestSupport.expect(
                !NotetakerCore.isValidIdentifier(hostile),
                "\(hostile) must be refused"
            )
        }
    }

    private static func aNoteStartsWithADatedTitle() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let title = NotetakerCore.defaultTitle(startedAt: date, calendar: calendar)
        TestSupport.expect(title.hasPrefix("Meeting on "), "got \(title)")
    }

    /// "Meeting on 3 October" tells you nothing a fortnight later.
    private static func aTitleIsSuggestedFromWhatWasSaid() {
        let title = NotetakerCore.suggestedTitle(
            from: "[0:00] You: Right, this is the quarterly budget review. Shall we start?"
        )
        TestSupport.expectEqual(
            title,
            "[0:00] You: Right, this is the quarterly budget review"
        )
    }

    private static func aVeryLongOpeningIsClippedOnAWord() {
        let long = String(repeating: "alpha ", count: 40) + "."
        let title = NotetakerCore.suggestedTitle(from: long, limit: 30)
        TestSupport.expect(title?.hasSuffix("…") == true, "clipped titles end in an ellipsis")
        TestSupport.expect((title?.count ?? 0) <= 31, "got \(title?.count ?? 0) characters")
        TestSupport.expect(title?.contains("alph…") != true, "clipped on a word, not mid-word")
    }

    private static func tooShortAnOpeningSuggestsNothing() {
        TestSupport.expect(NotetakerCore.suggestedTitle(from: "Hi.") == nil, "too short to title")
        TestSupport.expect(NotetakerCore.suggestedTitle(from: "") == nil, "nothing to title")
    }

    private static func speakersAreNumberedFromOne() {
        TestSupport.expectEqual(NotetakerCore.speakerName(forDiarizedIndex: 0), "Speaker 1")
        TestSupport.expectEqual(NotetakerCore.speakerName(forDiarizedIndex: 3), "Speaker 4")
    }
}
