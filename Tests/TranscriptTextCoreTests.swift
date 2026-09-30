import Foundation

enum TranscriptTextCoreTests {
    static func run() {
        testJSONTranscriptParsing()
        testNonTranscriptJSONFallsBackToUTF8()
        testInvalidTranscriptResponses()
        testHighConfidenceHallucinationsAreSuppressed()
        testPossibleRealSpeechIsPreserved()
        testPostProcessedTranscriptSanitization()
        testModeSpecificSanitization()
        testInstructionExecutionGuard()
        testLeakedPromptFencesAreStripped()
        testRealTextIsNotMistakenForAFence()
    }

    private static func testJSONTranscriptParsing() {
        let data = jsonData(["text": "Synthetic transcript."])
        TestSupport.expectEqual(
            try? TranscriptionResponseParser.parse(data),
            "Synthetic transcript."
        )

        let emptyData = jsonData(["text": ""])
        TestSupport.expectEqual(try? TranscriptionResponseParser.parse(emptyData), "")
    }

    private static func testNonTranscriptJSONFallsBackToUTF8() {
        let data = Data("{\n  \"synthetic\": \"fallback\"\n}".utf8)
        TestSupport.expectEqual(
            try? TranscriptionResponseParser.parse(data),
            "{   \"synthetic\": \"fallback\" }"
        )
    }

    private static func testInvalidTranscriptResponses() {
        expectInvalidResponse(Data())
        expectInvalidResponse(Data(" \n\t ".utf8))
        expectInvalidResponse(Data("{malformed synthetic JSON".utf8))
        expectInvalidResponse(Data([0xFF, 0xFE]))
    }

    private static func testHighConfidenceHallucinationsAreSuppressed() {
        let atThreshold = jsonData([
            "text": "Thank you.",
            "segments": [["no_speech_prob": 0.1]]
        ])
        TestSupport.expectEqual(try? TranscriptionResponseParser.parse(atThreshold), "")

        let normalizedPhrase = jsonData([
            "text": "  THANK YOU FOR WATCHING!!!  ",
            "segments": [["no_speech_prob": 0.9]]
        ])
        TestSupport.expectEqual(try? TranscriptionResponseParser.parse(normalizedPhrase), "")
    }

    private static func testPossibleRealSpeechIsPreserved() {
        let lowProbability = jsonData([
            "text": "Thank you.",
            "segments": [["no_speech_prob": 0.099]]
        ])
        TestSupport.expectEqual(try? TranscriptionResponseParser.parse(lowProbability), "Thank you.")

        let missingMetadata = jsonData(["text": "Thank you."])
        TestSupport.expectEqual(try? TranscriptionResponseParser.parse(missingMetadata), "Thank you.")

        let missingProbability = jsonData([
            "text": "Thank you.",
            "segments": [["synthetic": true]]
        ])
        TestSupport.expectEqual(try? TranscriptionResponseParser.parse(missingProbability), "Thank you.")

        let unrelatedSpeech = jsonData([
            "text": "Synthetic project update.",
            "segments": [["no_speech_prob": 0.95]]
        ])
        TestSupport.expectEqual(
            try? TranscriptionResponseParser.parse(unrelatedSpeech),
            "Synthetic project update."
        )
    }

    private static func testPostProcessedTranscriptSanitization() {
        TestSupport.expectEqual(
            TranscriptOutputSanitizer.postProcessedTranscript("  \"Synthetic output.\" \n"),
            "Synthetic output."
        )
        TestSupport.expectEqual(TranscriptOutputSanitizer.postProcessedTranscript("EMPTY"), "")
        TestSupport.expectEqual(TranscriptOutputSanitizer.postProcessedTranscript("\"EMPTY\""), "")
        TestSupport.expectEqual(TranscriptOutputSanitizer.postProcessedTranscript("empty"), "empty")
        TestSupport.expectEqual(TranscriptOutputSanitizer.postProcessedTranscript("  \n "), "")
    }

    private static func testModeSpecificSanitization() {
        TestSupport.expectEqual(
            TranscriptOutputSanitizer.verbatimTranslation("  \"EMPTY\"  "),
            "EMPTY"
        )
        TestSupport.expectEqual(
            TranscriptOutputSanitizer.verbatimTranslation(" \"Literal synthetic text.\" "),
            "Literal synthetic text."
        )
        TestSupport.expectEqual(
            TranscriptOutputSanitizer.commandModeTranscript("  \"Keep command quotes\" \n"),
            "\"Keep command quotes\""
        )
    }

    private static func testInstructionExecutionGuard() {
        TestSupport.expect(
            TranscriptOutputSanitizer.appearsToHaveExecutedInstruction(
                rawTranscript: "Write an email asking Alex for the synthetic report.",
                cleanedTranscript: "Sure, here's a draft: Hello Alex, please send the report.",
                outputLanguage: ""
            ),
            "Assistant-style execution should be rejected"
        )
        TestSupport.expect(
            TranscriptOutputSanitizer.appearsToHaveExecutedInstruction(
                rawTranscript: "Write a haiku about synthetic rain.",
                cleanedTranscript: "Soft drizzle taps windows.",
                outputLanguage: ""
            ),
            "Low-overlap instruction execution should be rejected"
        )
        TestSupport.expect(
            !TranscriptOutputSanitizer.appearsToHaveExecutedInstruction(
                rawTranscript: "Write an email asking Alex for the synthetic report.",
                cleanedTranscript: "Write an email asking Alex for the synthetic report.",
                outputLanguage: ""
            ),
            "Faithful cleanup should preserve instruction wording"
        )
        TestSupport.expect(
            !TranscriptOutputSanitizer.appearsToHaveExecutedInstruction(
                rawTranscript: "The synthetic launch is Friday.",
                cleanedTranscript: "Sure, the synthetic launch is Friday.",
                outputLanguage: ""
            ),
            "Ordinary speech without an instruction marker should not trigger the guard"
        )
        TestSupport.expect(
            !TranscriptOutputSanitizer.appearsToHaveExecutedInstruction(
                rawTranscript: "Translate the synthetic update.",
                cleanedTranscript: "Aggiornamento sintetico.",
                outputLanguage: "Italian"
            ),
            "Explicit translation output should bypass the instruction guard"
        )
    }

    private static func jsonData(_ object: [String: Any]) -> Data {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            fatalError("Synthetic JSON fixture should be serializable")
        }
        return data
    }

    private static func expectInvalidResponse(
        _ data: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            _ = try TranscriptionResponseParser.parse(data)
            TestSupport.expect(false, "Expected invalid response error", file: file, line: line)
        } catch let error as TranscriptionResponseParsingError {
            TestSupport.expectEqual(error, .invalidResponse, file: file, line: line)
        } catch {
            TestSupport.expect(
                false,
                "Expected TranscriptionResponseParsingError, got \(error)",
                file: file,
                line: line
            )
        }
    }

    /// Regression: a dictation came back with the model's own fence glued to
    /// the front of the sentence.
    private static func testLeakedPromptFencesAreStripped() {
        TestSupport.expectEqual(
            TranscriptOutputSanitizer.postProcessedTranscript(
                "<<<CLEANED_TRANSCRIPTION>>\nEn fait, je voulais voir si ça fonctionne comme ça."
            ),
            "En fait, je voulais voir si ça fonctionne comme ça."
        )

        // Same marker, glued to the text on one line.
        TestSupport.expectEqual(
            TranscriptOutputSanitizer.postProcessedTranscript(
                "<<<CLEANED_TRANSCRIPTION>> En fait, je voulais voir."
            ),
            "En fait, je voulais voir."
        )

        // The fence the prompt itself uses, echoed on both sides.
        TestSupport.expectEqual(
            TranscriptOutputSanitizer.postProcessedTranscript(
                "<<<RAW_TRANSCRIPTION\nHello there.\nRAW_TRANSCRIPTION"
            ),
            "Hello there."
        )

        // Markdown fences and bare punctuation rows.
        TestSupport.expectEqual(
            TranscriptOutputSanitizer.postProcessedTranscript("```\nHello there.\n```"),
            "Hello there."
        )
        TestSupport.expectEqual(
            TranscriptOutputSanitizer.postProcessedTranscript(">>>\nHello there.\n<<<"),
            "Hello there."
        )

        // Quotes still come off, and EMPTY still means empty.
        TestSupport.expectEqual(
            TranscriptOutputSanitizer.postProcessedTranscript("<<<OUTPUT>>\n\"Hello there.\""),
            "Hello there."
        )
        TestSupport.expectEqual(
            TranscriptOutputSanitizer.postProcessedTranscript("<<<CLEANED_TRANSCRIPTION>>\nEMPTY"),
            ""
        )

        // Edit Mode and verbatim translation share the fix.
        TestSupport.expectEqual(
            TranscriptOutputSanitizer.commandModeTranscript("<<<SELECTED_TEXT>>\nShorter version."),
            "Shorter version."
        )
        TestSupport.expectEqual(
            TranscriptOutputSanitizer.verbatimTranslation("<<<TRANSCRIPT\nBonjour.\nTRANSCRIPT"),
            "Bonjour."
        )
    }

    /// The stripper must not eat speech. Only the edges are considered, and a
    /// bare uppercase word is removed only when it is one of the prompt's own
    /// section names.
    private static func testRealTextIsNotMistakenForAFence() {
        let unchanged = [
            "Hello there.",
            // An acronym the user actually dictated, at the start of a sentence.
            "HTTP is the protocol we use.",
            "Send it to NASA tomorrow.",
            // Uppercase words in the middle must survive untouched.
            "The header says CONTEXT and then the body follows.",
            // Multi-line dictation keeps its shape.
            "First line.\nSecond line.",
            // Comparison operators are not fences when they carry text.
            "Use a < b to compare them."
        ]
        for text in unchanged {
            TestSupport.expectEqual(TranscriptOutputSanitizer.postProcessedTranscript(text), text)
        }

        // A standalone acronym line that is NOT one of our markers survives.
        TestSupport.expectEqual(
            TranscriptOutputSanitizer.postProcessedTranscript("NASA"),
            "NASA"
        )
    }
}
