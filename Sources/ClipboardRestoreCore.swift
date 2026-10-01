import Foundation

/// Whether to put back the clipboard a dictation borrowed.
///
/// Pure, because the rule has three cases and one of them was nearly lost.
///
/// Pasting goes through the clipboard, so ZFlow writes the transcript there,
/// pastes, and a moment later puts back what the user had. It restores when
/// nothing touched the clipboard since, or when it still holds exactly the
/// transcript — browsers and clipboard sync bump the change count on their
/// own. But Copy in the not-pasted toast also leaves exactly the transcript
/// there, on purpose, and restoring over it undid the copy without a word.
enum ClipboardRestoreCore {
    static func shouldRestore(
        changeCount: Int,
        expectedChangeCount: Int,
        currentText: String?,
        writtenTranscript: String,
        deliberateCopyChangeCount: Int?
    ) -> Bool {
        // A copy made on purpose is the user's, whatever it holds.
        if let deliberateCopyChangeCount, deliberateCopyChangeCount == changeCount {
            return false
        }
        return changeCount == expectedChangeCount || currentText == writtenTranscript
    }
}
