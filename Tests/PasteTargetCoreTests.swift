import Foundation

enum PasteTargetCoreTests {
    static func run() {
        noFocusAtAllMeansTheTextWentNowhere()
        aPageOrAListIsNotSomewhereToType()
        textFieldsAreTargets()
        editableContentWinsOverItsRole()
        selfDrawnEditorsAreNeverAccused()
        shortTextIsShownWhole()
        longTextIsCutAtAWordWithAnEllipsis()
        aSingleLongWordIsStillCut()
    }

    private typealias Focus = PasteTargetCore.Focus

    /// The case behind the request: the focus moved to something with no
    /// field, and the paste fell on nothing.
    private static func noFocusAtAllMeansTheTextWentNowhere() {
        TestSupport.expectEqual(PasteTargetCore.verdict(for: nil), .nowhere)
    }

    private static func aPageOrAListIsNotSomewhereToType() {
        for role in ["AXWebArea", "AXList", "AXOutline", "AXTable", "AXButton", "AXScrollArea"] {
            TestSupport.expectEqual(PasteTargetCore.verdict(for: Focus(role: role)), .nowhere)
        }
    }

    private static func textFieldsAreTargets() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox"] {
            TestSupport.expectEqual(PasteTargetCore.verdict(for: Focus(role: role)), .textField)
        }
        // A search field is a text field with a subrole.
        TestSupport.expectEqual(
            PasteTargetCore.verdict(for: Focus(role: "AXGroup", subrole: "AXSearchField")),
            .textField
        )
    }

    /// A web page in design mode, or a cell being edited: the role says
    /// "not text", the element says otherwise, and the element is right.
    private static func editableContentWinsOverItsRole() {
        TestSupport.expectEqual(
            PasteTargetCore.verdict(for: Focus(role: "AXWebArea", valueSettable: true)),
            .textField
        )
        TestSupport.expectEqual(
            PasteTargetCore.verdict(for: Focus(role: "AXCell", hasInsertionPoint: true)),
            .textField
        )
    }

    /// The false alarm to avoid: GPU terminals and canvas editors report a
    /// window or a group and take the paste fine. Offering the text back
    /// after every dictation there would be worse than the problem.
    private static func selfDrawnEditorsAreNeverAccused() {
        for role in ["AXWindow", "AXGroup", "AXSomethingNew"] {
            TestSupport.expectEqual(PasteTargetCore.verdict(for: Focus(role: role)), .unknown)
        }
        TestSupport.expectEqual(PasteTargetCore.verdict(for: Focus(role: nil)), .unknown)
    }

    private static func shortTextIsShownWhole() {
        TestSupport.expectEqual(PasteTargetCore.preview(of: "  Bonjour à tous.  "), "Bonjour à tous.")
        let exact = String(repeating: "a", count: PasteTargetCore.previewLimit)
        TestSupport.expectEqual(PasteTargetCore.preview(of: exact), exact)
    }

    private static func longTextIsCutAtAWordWithAnEllipsis() {
        let text = Array(repeating: "mot", count: 400).joined(separator: " ")
        let preview = PasteTargetCore.preview(of: text)
        TestSupport.expect(preview.hasSuffix("mot…"), "the preview should end on a whole word: \(preview.suffix(12))")
        TestSupport.expect(
            preview.count <= PasteTargetCore.previewLimit,
            "the preview is \(preview.count) characters, over the \(PasteTargetCore.previewLimit) limit"
        )
        TestSupport.expect(preview.count >= 500, "the preview should show a good part of the text, got \(preview.count)")
    }

    private static func aSingleLongWordIsStillCut() {
        let preview = PasteTargetCore.preview(of: String(repeating: "x", count: 2000), limit: 100)
        TestSupport.expectEqual(preview.count, 100)
        TestSupport.expect(preview.hasSuffix("…"), "a cut preview must say so")
    }
}
