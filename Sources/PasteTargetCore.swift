import Foundation

/// Whether a paste had somewhere to go, judged from what had the focus.
///
/// Pure, so the rules are tested without another app's Accessibility tree.
///
/// macOS never says whether a synthetic Cmd+V inserted anything. Reading the
/// field back afterwards is no proof either: editors that draw their own text
/// — code editors, canvas documents, some terminals — take the paste and
/// expose none of it. So the question asked is the one that can be answered:
/// was the focus on something that takes text at all. Only a clear "no" offers
/// the text back; anything uncertain stays quiet, because a toast after every
/// dictation in an app that worked fine would be worse than the problem.
enum PasteTargetCore {
    /// What Accessibility reported for the focused element at paste time.
    struct Focus: Equatable {
        var role: String?
        var subrole: String?
        /// The element's value can be set: it holds editable content.
        var valueSettable: Bool = false
        /// It has a caret. Only editable text exposes an insertion point.
        var hasInsertionPoint: Bool = false
    }

    enum Verdict: Equatable {
        /// The focus was on something that takes text.
        case textField
        /// The focus was nowhere, or on something that cannot take text.
        case nowhere
        /// Could not tell. Treated as pasted.
        case unknown
    }

    static let textRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField",
    ]

    /// Elements that take focus but never text: a page with no field active,
    /// a file list, a sidebar, a button.
    ///
    /// AXWindow and AXGroup are deliberately absent. Editors that draw their
    /// own text — GPU terminals, canvas apps — often report one of those while
    /// accepting the paste perfectly well.
    static let nonTextRoles: Set<String> = [
        "AXWebArea", "AXList", "AXOutline", "AXTable", "AXBrowser", "AXScrollArea",
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
        "AXDisclosureTriangle", "AXLink", "AXImage", "AXStaticText", "AXCell", "AXRow",
        "AXColumn", "AXToolbar", "AXTabGroup", "AXSplitGroup", "AXMenuBar", "AXMenu",
        "AXMenuItem", "AXApplication",
    ]

    /// `nil` focus means the application reported no focused element at all.
    static func verdict(for focus: Focus?) -> Verdict {
        guard let focus else { return .nowhere }

        // Editable content wins over the role: a document in design mode is a
        // web area, and a cell being edited is a cell.
        if focus.valueSettable || focus.hasInsertionPoint { return .textField }

        if let role = focus.role, textRoles.contains(role) { return .textField }
        if let subrole = focus.subrole, textRoles.contains(subrole) { return .textField }
        if let role = focus.role, nonTextRoles.contains(role) { return .nowhere }
        return .unknown
    }

    /// The text offered back is the whole transcript; this is only what fits
    /// on screen. Roughly the 500 to 1,000 characters a glance can take in.
    static let previewLimit = 800

    /// Lines shown before the preview is cut, whatever its length.
    static let previewLines = 12

    /// The transcript cut to `limit` characters, at a word where one is close,
    /// with an ellipsis when anything was dropped.
    static func preview(of text: String, limit: Int = previewLimit) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit, limit > 1 else { return trimmed }

        var cut = String(trimmed.prefix(limit - 1))
        // Back up to the last space if one is near, so the preview does not
        // end on half a word. Not too far: a long word is still worth showing.
        if let space = cut.lastIndex(where: { $0.isWhitespace }),
           cut.distance(from: space, to: cut.endIndex) <= 40 {
            cut = String(cut[..<space])
        }
        return cut.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
