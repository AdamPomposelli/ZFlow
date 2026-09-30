import Foundation

enum LearnedCorrectionsCoreTests {
    static func run() {
        testBrandNameCorrectionIsDetected()
        testRewordingIsNotLearned()
        testImplausiblePairsAreRejected()
        testCorrectionsAreAppliedOnWordBoundaries()
        testMergingKeepsTheNewestSpelling()
        testSentenceCapitalizationIsNotLearned()
        testOnlyThePastedRegionIsCompared()
        testCompletedMultiWordNameIsLearned()
        testOrdinaryInsertionsAreNotLearned()
        testGarbledNameIsLearned()
        testHeavilyMisheardNameIsLearned()
        testGroupingAndEditing()
        testAdjudicatorVerdictsAreParsedStrictly()
    }

    /// The dangerous false positive: editing "The" to "the" must not teach a
    /// rule that rewrites every "the" in every later dictation.
    private static func testSentenceCapitalizationIsNotLearned() {
        TestSupport.expect(
            CorrectionDetector.corrections(
                from: "The meeting starts at noon",
                to: "the meeting starts at noon"
            ).isEmpty,
            "Sentence-initial capitalization should not be learned"
        )
        TestSupport.expect(
            CorrectionDetector.corrections(
                from: "we met yesterday",
                to: "We met yesterday"
            ).isEmpty,
            "Capitalizing the first word should not be learned"
        )

        // But a genuinely distinctive capital is still learned.
        TestSupport.expect(
            CorrectionDetector.hasDistinctiveCapitalization("ZenMux"),
            "An internal capital is distinctive"
        )
        TestSupport.expect(
            CorrectionDetector.hasDistinctiveCapitalization("NASA"),
            "An acronym is distinctive"
        )
        TestSupport.expect(
            !CorrectionDetector.hasDistinctiveCapitalization("The"),
            "A leading capital alone is not distinctive"
        )
        TestSupport.expect(
            !CorrectionDetector.hasDistinctiveCapitalization("the"),
            "Lowercase is not distinctive"
        )
    }

    private static func testBrandNameCorrectionIsDetected() {
        // The motivating case: a brand the model spells as ordinary words.
        let found = CorrectionDetector.corrections(
            from: "I pushed the change to Zen mux this morning.",
            to: "I pushed the change to ZenMux this morning."
        )
        TestSupport.expectEqual(found.count, 1)
        TestSupport.expectEqual(found.first?.corrected, "ZenMux")

        // Case-only fixes are the most common kind and must be kept.
        let casing = CorrectionDetector.corrections(
            from: "we deployed acmecorp yesterday",
            to: "we deployed AcmeCorp yesterday"
        )
        TestSupport.expectEqual(casing.count, 1)
        TestSupport.expectEqual(casing.first?.original, "acmecorp")
        TestSupport.expectEqual(casing.first?.corrected, "AcmeCorp")

        // A misspelling of a proper noun.
        let spelling = CorrectionDetector.corrections(
            from: "ask Kubernetis about the pods",
            to: "ask Kubernetes about the pods"
        )
        TestSupport.expectEqual(spelling.first?.corrected, "Kubernetes")
    }

    private static func testRewordingIsNotLearned() {
        // Unchanged text teaches nothing.
        TestSupport.expect(
            CorrectionDetector.corrections(from: "same text here", to: "same text here").isEmpty,
            "Identical text should yield no corrections"
        )

        // A rewritten sentence is not a spelling fix.
        TestSupport.expect(
            CorrectionDetector.corrections(
                from: "the meeting is on Tuesday at noon",
                to: "let us reschedule for Thursday evening instead"
            ).isEmpty,
            "A rewrite should not be learned"
        )

        // Changing one's mind about a word is not a correction.
        TestSupport.expect(
            CorrectionDetector.corrections(
                from: "bring the cat inside now",
                to: "bring the dog inside now"
            ).isEmpty,
            "An unrelated word swap should not be learned"
        )

        // Continuing to type after the paste is not a correction either.
        TestSupport.expect(
            CorrectionDetector.corrections(
                from: "hello there",
                to: "hello there and here is a lot more text I typed myself"
            ).isEmpty,
            "Appended text should not be learned"
        )
    }

    private static func testImplausiblePairsAreRejected() {
        TestSupport.expect(
            CorrectionDetector.isPlausibleCorrection(original: "zenmux", corrected: "ZenMux"),
            "Case-only changes are corrections"
        )
        TestSupport.expect(
            CorrectionDetector.isPlausibleCorrection(original: "Kubernetis", corrected: "Kubernetes"),
            "A one-letter spelling fix is a correction"
        )
        TestSupport.expect(
            !CorrectionDetector.isPlausibleCorrection(original: "cat", corrected: "dog"),
            "Unrelated words are not corrections"
        )
        TestSupport.expect(
            !CorrectionDetector.isPlausibleCorrection(original: "an", corrected: "the"),
            "Very short words are not learned"
        )
        TestSupport.expect(
            !CorrectionDetector.isPlausibleCorrection(original: "2024", corrected: "2025"),
            "Numbers are values, not spellings"
        )
        TestSupport.expect(
            !CorrectionDetector.isPlausibleCorrection(original: "word", corrected: "word"),
            "An unchanged word is not a correction"
        )
    }

    private static func testCorrectionsAreAppliedOnWordBoundaries() {
        let rules = [WordCorrection(original: "zenmux", corrected: "ZenMux")]

        TestSupport.expectEqual(
            LearnedCorrectionStore.applying(rules, to: "I use zenmux daily"),
            "I use ZenMux daily"
        )
        // Matching is case-insensitive so any mishearing is caught.
        TestSupport.expectEqual(
            LearnedCorrectionStore.applying(rules, to: "I use ZENMUX daily"),
            "I use ZenMux daily"
        )
        // But it must not fire inside a longer word.
        TestSupport.expectEqual(
            LearnedCorrectionStore.applying(rules, to: "zenmuxing is not a word"),
            "zenmuxing is not a word"
        )
        // Punctuation still counts as a boundary.
        TestSupport.expectEqual(
            LearnedCorrectionStore.applying(rules, to: "try zenmux, then stop"),
            "try ZenMux, then stop"
        )
        // Accented neighbours must not be treated as boundaries.
        let accented = [WordCorrection(original: "eleve", corrected: "élève")]
        TestSupport.expectEqual(
            LearnedCorrectionStore.applying(accented, to: "un eleve arrive"),
            "un élève arrive"
        )
        TestSupport.expectEqual(
            LearnedCorrectionStore.applying(rules, to: "nothing to change"),
            "nothing to change"
        )
    }

    private static func testMergingKeepsTheNewestSpelling() {
        let start = Date(timeIntervalSince1970: 1_000)
        var list = LearnedCorrectionStore.merging(
            WordCorrection(original: "zenmux", corrected: "Zenmux"),
            into: [],
            now: start
        )
        TestSupport.expectEqual(list.count, 1)
        TestSupport.expectEqual(list[0].occurrences, 1)

        // Correcting the same word again updates the spelling and the count
        // rather than adding a second, conflicting rule.
        list = LearnedCorrectionStore.merging(
            WordCorrection(original: "ZENMUX", corrected: "ZenMux"),
            into: list,
            now: start.addingTimeInterval(60)
        )
        TestSupport.expectEqual(list.count, 1)
        TestSupport.expectEqual(list[0].corrected, "ZenMux")
        TestSupport.expectEqual(list[0].occurrences, 2)

        // The list stays bounded, keeping the most recent entries.
        var many: [WordCorrection] = []
        for index in 0..<(LearnedCorrectionStore.maximumCount + 20) {
            many = LearnedCorrectionStore.merging(
                WordCorrection(original: "word\(index)", corrected: "Word\(index)"),
                into: many,
                now: start.addingTimeInterval(Double(index))
            )
        }
        TestSupport.expectEqual(many.count, LearnedCorrectionStore.maximumCount)
        TestSupport.expectEqual(many.first?.original, "word\(LearnedCorrectionStore.maximumCount + 19)")
    }

    /// Only the dictated text is diffed. Anything the user types around it
    /// must stay out of the comparison, or their own writing would be read as
    /// a correction.
    private static func testOnlyThePastedRegionIsCompared() {
        let pasted = "I pushed the change to Zen mux this morning."

        // Text typed before and after the paste is excluded.
        TestSupport.expectEqual(
            CorrectionWatcher.editedRegion(
                pasted: pasted,
                in: "Note to self: I pushed the change to ZenMux this morning. TODO follow up."
            ),
            "I pushed the change to ZenMux this morning"
        )

        // An untouched paste comes back exactly.
        TestSupport.expectEqual(
            CorrectionWatcher.editedRegion(pasted: pasted, in: "before. \(pasted) after."),
            pasted
        )

        // If the anchors are gone, there is nothing safe to compare.
        TestSupport.expectEqual(
            CorrectionWatcher.editedRegion(pasted: pasted, in: "something else entirely"),
            nil
        )

        // A region that ballooned means the user wrote between the anchors.
        TestSupport.expectEqual(
            CorrectionWatcher.editedRegion(
                pasted: pasted,
                in: "I " + String(repeating: "typed a great deal more here ", count: 8) + "morning."
            ),
            nil
        )
    }

    /// Regression: the transcriber heard only part of a two-word brand and the
    /// user typed the missing word in front of it. The insertion is not a
    /// respelling, so the edit-distance rules never saw it.
    private static func testCompletedMultiWordNameIsLearned() {
        let found = CorrectionDetector.corrections(
            from: "Là je voulais faire un test et parler de la marque Haven qui est ma marque.",
            to: "Là je voulais faire un test et parler de la marque Hoop Haven qui est ma marque."
        )
        TestSupport.expectEqual(found.count, 1)
        TestSupport.expectEqual(found.first?.original, "Haven")
        TestSupport.expectEqual(found.first?.corrected, "Hoop Haven")

        // A word appended after the name works the same way.
        let suffix = CorrectionDetector.corrections(
            from: "we are launching Hoop next week",
            to: "we are launching Hoop Haven next week"
        )
        TestSupport.expectEqual(suffix.first?.corrected, "Hoop Haven")

        // And the learned rule then rewrites later dictations.
        TestSupport.expectEqual(
            LearnedCorrectionStore.applying(
                [WordCorrection(original: "Haven", corrected: "Hoop Haven")],
                to: "I work on Haven every day"
            ),
            "I work on Hoop Haven every day"
        )
    }

    /// The expansion rule must not turn ordinary added words into a rule that
    /// rewrites every later dictation.
    private static func testOrdinaryInsertionsAreNotLearned() {
        TestSupport.expect(
            CorrectionDetector.corrections(
                from: "I went to the store today",
                to: "I went to the big store today"
            ).isEmpty,
            "A lowercase adjective is not part of a name"
        )
        TestSupport.expect(
            !CorrectionDetector.isPlausibleExpansion(original: "store", corrected: "big store"),
            "Lowercase expansions are rejected"
        )
        TestSupport.expect(
            CorrectionDetector.isPlausibleExpansion(original: "Haven", corrected: "Hoop Haven"),
            "A capitalised two-word name is an expansion"
        )
        TestSupport.expect(
            !CorrectionDetector.isPlausibleExpansion(original: "Haven", corrected: "Hoop Haven Is A Very Long Thing"),
            "Adding a whole clause is not an expansion"
        )
        TestSupport.expect(
            !CorrectionDetector.isPlausibleExpansion(original: "Haven", corrected: "Hoop Sanctuary"),
            "The heard word must survive inside the expansion"
        )
    }

    /// Regression: the transcriber ran a two-word brand together and misspelled
    /// it. Four edits against a budget of two, so the distance rule refused it,
    /// and the heard word does not survive whole, so the expansion rule did too.
    private static func testGarbledNameIsLearned() {
        let found = CorrectionDetector.corrections(
            from: "Je voulais faire un test de la nouvelle fonctionnalité avec ma marque Hoaven que j'adore",
            to: "Je voulais faire un test de la nouvelle fonctionnalité avec ma marque Hoop Haven que j'adore."
        )
        TestSupport.expectEqual(found.count, 1)
        TestSupport.expectEqual(found.first?.original, "Hoaven")
        TestSupport.expectEqual(found.first?.corrected, "Hoop Haven")

        TestSupport.expect(
            CorrectionDetector.isPlausibleProperNounRespelling(original: "Hoaven", corrected: "Hoop Haven"),
            "Spacing and a letter is a name the model ran together"
        )
        // The looser budget is paid for by the name shape, so ordinary words
        // cannot use it.
        TestSupport.expect(
            !CorrectionDetector.isPlausibleProperNounRespelling(original: "meeting", corrected: "Hoop Haven"),
            "An unrelated word is not a respelling"
        )
        TestSupport.expect(
            !CorrectionDetector.isPlausibleProperNounRespelling(original: "test", corrected: "Test"),
            "A leading capital is a sentence, not a name"
        )
        TestSupport.expect(
            !CorrectionDetector.isPlausibleProperNounRespelling(original: "store", corrected: "big store"),
            "Lowercase words are not a name"
        )
        // A phrase must not read as having an internal capital just because its
        // second word is capitalised.
        TestSupport.expect(
            !CorrectionDetector.hasDistinctiveCapitalization("marque Hoop"),
            "A lowercase word followed by a capitalised one is not a name"
        )
        TestSupport.expect(
            CorrectionDetector.hasDistinctiveCapitalization("Hoop Haven"),
            "Two capitalised words are a name"
        )
    }

    /// The model's verdict is data, not a command: anything malformed, or too
    /// large to be a name, must not become a rewriting rule.
    private static func testAdjudicatorVerdictsAreParsedStrictly() {
        let good = CorrectionAdjudicator.parseVerdict("CORRECTION: Hoaven => Hoop Haven")
        TestSupport.expectEqual(good?.original, "Hoaven")
        TestSupport.expectEqual(good?.corrected, "Hoop Haven")

        // Quotes and stray prose around the line are tolerated.
        let quoted = CorrectionAdjudicator.parseVerdict("CORRECTION: \"Hoaven\" => \"Hoop Haven\"")
        TestSupport.expectEqual(quoted?.corrected, "Hoop Haven")

        for refused in [
            "NONE",
            "I think the user changed their mind.",
            "CORRECTION: Hoaven",
            "CORRECTION:  => Hoop Haven",
            "CORRECTION: Hoaven => ",
            // A whole clause would rewrite every later transcript.
            "CORRECTION: the meeting starts at noon => the meeting starts at one",
            "CORRECTION: ab => Hoop"
        ] {
            TestSupport.expect(
                CorrectionAdjudicator.parseVerdict(refused) == nil,
                "Should refuse: \(refused)"
            )
        }

        // Only a lightly edited sentence is worth a model call.
        TestSupport.expect(
            CorrectionAdjudicator.isWorthAsking(
                pasted: "avec ma marque Hoaven que j'adore vraiment beaucoup",
                edited: "avec ma marque Hoop Haven que j'adore vraiment beaucoup"
            ),
            "A one-word change in a familiar sentence is worth asking about"
        )
        TestSupport.expect(
            !CorrectionAdjudicator.isWorthAsking(
                pasted: "the meeting is on Tuesday at noon",
                edited: "let us reschedule for Thursday evening instead please"
            ),
            "A rewrite is not worth asking about"
        )
    }

    /// Regression: the transcriber produced "Upaven" for "Hoop Haven" — four
    /// edits once spacing is ignored, right at the similarity threshold.
    private static func testHeavilyMisheardNameIsLearned() {
        let found = CorrectionDetector.corrections(
            from: "Je voulais faire un test de ma marque Upaven que j'adore énormément.",
            to: "Je voulais faire un test de ma marque Hoop Haven que j'adore énormément."
        )
        TestSupport.expectEqual(found.count, 1)
        TestSupport.expectEqual(found.first?.original, "Upaven")
        TestSupport.expectEqual(found.first?.corrected, "Hoop Haven")

        // The rule then rewrites a later dictation.
        TestSupport.expectEqual(
            LearnedCorrectionStore.applying(
                [WordCorrection(original: "Upaven", corrected: "Hoop Haven")],
                to: "Upaven est ma marque"
            ),
            "Hoop Haven est ma marque"
        )
    }

    /// The settings list groups rules by the spelling they produce, so several
    /// heard forms can point at one word, and both sides can be edited.
    private static func testGroupingAndEditing() {
        var list: [WordCorrection] = []
        list = LearnedCorrectionStore.addingVariant("Paven", correctedTo: "HoopHaven", in: list)
        list = LearnedCorrectionStore.addingVariant("Hoaven", correctedTo: "HoopHaven", in: list)
        list = LearnedCorrectionStore.addingVariant("zenmux", correctedTo: "ZenMux", in: list)

        let groups = LearnedCorrectionStore.grouped(list)
        TestSupport.expectEqual(groups.count, 2)
        let hoop = groups.first { $0.corrected == "HoopHaven" }
        TestSupport.expectEqual(hoop?.variants.count, 2)
        TestSupport.expectEqual(
            Set(hoop?.variants.map(\.original) ?? []),
            Set(["Paven", "Hoaven"])
        )

        // Renaming the spelling moves every variant in the group, and nothing else.
        list = LearnedCorrectionStore.renamingCorrected(from: "HoopHaven", to: "Hoop Haven", in: list)
        TestSupport.expect(
            list.filter { $0.corrected == "Hoop Haven" }.count == 2,
            "Both variants should follow the rename"
        )
        TestSupport.expect(
            list.contains { $0.corrected == "ZenMux" },
            "Other groups are untouched"
        )

        // Editing one heard form leaves its spelling alone.
        list = LearnedCorrectionStore.replacingVariant(id: "paven", with: "Pavenn", in: list)
        TestSupport.expect(
            list.contains { $0.original == "Pavenn" && $0.corrected == "Hoop Haven" },
            "The variant is renamed in place"
        )

        // A case-only rule is meaningful and must survive: "zenmux" ->
        // "ZenMux" is the most common correction there is.
        TestSupport.expect(
            list.contains { $0.original == "zenmux" && $0.corrected == "ZenMux" },
            "A case-only rule is kept"
        )

        // A rule mapping a word to itself exactly is meaningless and is dropped.
        let selfMapping = LearnedCorrectionStore.renamingCorrected(
            from: "ZenMux",
            to: "zenmux",
            in: list
        )
        TestSupport.expect(
            !selfMapping.contains { $0.original == $0.corrected },
            "A variant identical to its own spelling is removed"
        )

        // Empty edits are refused rather than destroying the rule.
        TestSupport.expectEqual(
            LearnedCorrectionStore.renamingCorrected(from: "Hoop Haven", to: "  ", in: list).count,
            list.count
        )
        TestSupport.expectEqual(
            LearnedCorrectionStore.replacingVariant(id: "pavenn", with: "", in: list).count,
            list.count
        )
        TestSupport.expectEqual(
            LearnedCorrectionStore.addingVariant("", correctedTo: "Hoop Haven", in: list).count,
            list.count
        )
        // A heard form another rule already claims is refused.
        TestSupport.expectEqual(
            LearnedCorrectionStore.replacingVariant(id: "pavenn", with: "Hoaven", in: list).count,
            list.count
        )

        // Every variant in a group rewrites the transcript.
        let applied = LearnedCorrectionStore.applying(
            list,
            to: "Pavenn et Hoaven sont la même marque"
        )
        TestSupport.expectEqual(applied, "Hoop Haven et Hoop Haven sont la même marque")

        // Removing a group removes all of its variants.
        let withoutHoop = LearnedCorrectionStore.removingGroup(corrected: "Hoop Haven", in: list)
        TestSupport.expect(
            !withoutHoop.contains { $0.corrected == "Hoop Haven" },
            "The whole group goes"
        )
        TestSupport.expect(withoutHoop.contains { $0.corrected == "ZenMux" }, "Others stay")
    }
}
