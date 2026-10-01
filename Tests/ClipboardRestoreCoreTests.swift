import Foundation

enum ClipboardRestoreCoreTests {
    static func run() {
        anUntouchedClipboardIsRestored()
        aBackgroundBumpStillRestores()
        somethingTheUserCopiedIsKept()
        aCopyFromTheToastIsKept()
        anOlderToastCopyDoesNotBlockRestoring()
    }

    private static func restore(
        changeCount: Int,
        currentText: String?,
        deliberate: Int? = nil
    ) -> Bool {
        ClipboardRestoreCore.shouldRestore(
            changeCount: changeCount,
            expectedChangeCount: 10,
            currentText: currentText,
            writtenTranscript: "texte dicté",
            deliberateCopyChangeCount: deliberate
        )
    }

    private static func anUntouchedClipboardIsRestored() {
        TestSupport.expect(restore(changeCount: 10, currentText: "texte dicté"), "nothing touched it: restore")
    }

    /// Existing behaviour, kept: a browser or clipboard sync bumped the count
    /// without the user copying anything.
    private static func aBackgroundBumpStillRestores() {
        TestSupport.expect(restore(changeCount: 11, currentText: "texte dicté"), "a background bump should not strand the transcript")
    }

    private static func somethingTheUserCopiedIsKept() {
        TestSupport.expect(!restore(changeCount: 11, currentText: "autre chose"), "the user's own copy must not be clobbered")
    }

    /// The regression: Copy in the not-pasted toast leaves exactly the
    /// transcript, and the restore took it for a background bump.
    private static func aCopyFromTheToastIsKept() {
        TestSupport.expect(
            !restore(changeCount: 11, currentText: "texte dicté", deliberate: 11),
            "a copy made from the toast must survive the restore"
        )
    }

    /// Only the copy still on the clipboard counts: once something newer is
    /// there, the ordinary rule applies again.
    private static func anOlderToastCopyDoesNotBlockRestoring() {
        TestSupport.expect(
            restore(changeCount: 10, currentText: "texte dicté", deliberate: 4),
            "a stale toast copy should not block an ordinary restore"
        )
    }
}
