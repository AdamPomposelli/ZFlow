import Foundation

enum LocaleReservationCoreTests {
    static func run() {
        nothingToDoWhenAlreadyReserved()
        theOldestSlotIsGivenUp()
        theSystemLanguageIsNeverGivenUp()
        separatorsDoNotMakeADifferentLocale()
        nothingToReleaseWhenNothingIsHeld()
    }

    private static func release(_ reserved: [String], _ wanted: String, keeping: String? = nil) -> String? {
        LocaleReservationCore.reservationToRelease(reserved: reserved, wanted: wanted, keeping: keeping)
    }

    private static func nothingToDoWhenAlreadyReserved() {
        TestSupport.expect(release(["fr_FR", "en_US"], "fr_FR") == nil, "already held")
    }

    /// macOS returns reservations in the order they were claimed, so the front
    /// is the one least likely to be wanted next.
    private static func theOldestSlotIsGivenUp() {
        TestSupport.expectEqual(release(["ja_JP", "de_DE", "en_US"], "fr_FR"), "ja_JP")
    }

    /// An empty language setting falls back to the system language, so that
    /// slot has to survive or the fallback breaks instead.
    private static func theSystemLanguageIsNeverGivenUp() {
        TestSupport.expectEqual(
            release(["en_US", "ja_JP"], "fr_FR", keeping: "en_US"),
            "ja_JP"
        )
        TestSupport.expect(
            release(["en_US"], "fr_FR", keeping: "en_US") == nil,
            "the only slot is the system one, so there is nothing to give up"
        )
    }

    private static func separatorsDoNotMakeADifferentLocale() {
        TestSupport.expect(release(["fr-FR"], "fr_FR") == nil, "fr-FR is fr_FR")
        TestSupport.expect(release(["FR_fr"], "fr_FR") == nil, "case does not matter")
    }

    private static func nothingToReleaseWhenNothingIsHeld() {
        TestSupport.expect(release([], "fr_FR") == nil, "no slots held")
    }
}
