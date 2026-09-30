import Foundation

/// Which of the app's locale slots to give up when they are all taken.
///
/// macOS lets an app hold only a handful of speech locales at once, and the
/// reservation outlives the process: try five languages over a few weeks and
/// the sixth fails for ever, with nothing on screen to say why. Releasing a
/// slot is cheap — the downloaded assets stay on disk and reserving it again
/// later costs nothing — so refusing to transcribe because of a language
/// nobody has spoken in a month is the wrong answer.
public enum LocaleReservationCore {
    /// The slot to release so `wanted` can be reserved, or nil if there is
    /// nothing to do.
    ///
    /// Never the wanted locale itself, and never the one being kept for the
    /// system language, which is what an empty language setting falls back to.
    public static func reservationToRelease(
        reserved: [String],
        wanted: String,
        keeping systemLocale: String? = nil
    ) -> String? {
        guard !reserved.contains(where: { matches($0, wanted) }) else { return nil }
        let candidates = reserved.filter { slot in
            if matches(slot, wanted) { return false }
            if let systemLocale, matches(slot, systemLocale) { return false }
            return true
        }
        // The oldest reservation, which is the one at the front: macOS returns
        // them in the order they were claimed.
        return candidates.first
    }

    /// "fr_FR" and "fr-FR" name the same reservation.
    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        lhs.replacingOccurrences(of: "-", with: "_").caseInsensitiveCompare(
            rhs.replacingOccurrences(of: "-", with: "_")
        ) == .orderedSame
    }
}
