import Foundation

/// A word the transcriber got wrong and the spelling the user typed instead.
public struct WordCorrection: Codable, Equatable, Hashable, Identifiable {
    public let original: String
    public let corrected: String
    public var occurrences: Int
    public var lastSeen: Date

    public var id: String { original.lowercased() }

    public init(original: String, corrected: String, occurrences: Int = 1, lastSeen: Date = Date()) {
        self.original = original
        self.corrected = corrected
        self.occurrences = occurrences
        self.lastSeen = lastSeen
    }
}

/// Finds the words a user fixed by hand in text ZFlow had just pasted.
///
/// The target is the case WisprFlow handles well: a brand or proper noun the
/// speech model spells as ordinary words, which the user then retypes. Getting
/// this wrong is worse than not learning at all — a bad rule silently rewrites
/// later dictations — so the detector is deliberately reluctant, and only
/// accepts a substitution that looks like a spelling fix of the same word.
public enum CorrectionDetector {
    /// A single edit can only be a correction if the two words are close. This
    /// keeps "cat" → "dog", where the user simply changed their mind, out of
    /// the dictionary, while allowing "Zen mux" → "ZenMux".
    public static func isPlausibleCorrection(original: String, corrected: String) -> Bool {
        let from = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = corrected.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !from.isEmpty, !to.isEmpty, from != to else { return false }
        // Very short words are too easy to confuse with an ordinary reword.
        guard from.count >= 3, to.count >= 2 else { return false }
        // A number is a value the user changed, not a spelling they fixed.
        guard !from.allSatisfy(\.isNumber), !to.allSatisfy(\.isNumber) else { return false }

        // Case-only changes are the single most useful correction to learn —
        // "zenmux" -> "ZenMux" is exactly the brand-name case — but only when
        // the new spelling carries a capital that a sentence would not explain.
        // Otherwise editing "The" to "the" would teach a rule that rewrites
        // every "the" the user ever dictates.
        if from.lowercased() == to.lowercased() {
            return hasDistinctiveCapitalization(to)
        }

        let distance = levenshtein(from.lowercased(), to.lowercased())
        let budget = max(1, from.count / 3)
        return distance <= budget
    }

    /// True when a word was respelled into a proper noun the edit-distance
    /// budget is too tight to recognise.
    ///
    /// "Hoaven" -> "Hoop Haven" is four edits against a budget of two, because
    /// the budget is sized for a typo, not for a name the transcriber ran
    /// together. Spacing is the thing it got wrong, so the comparison ignores
    /// spaces, and the looser threshold is paid for by requiring the result to
    /// be unmistakably a name: several capitalised words, or a capital no
    /// sentence would explain.
    public static func isPlausibleProperNounRespelling(
        original: String,
        corrected: String
    ) -> Bool {
        let from = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard from.count >= 3, to.count >= 3 else { return false }

        let fromWords = tokenize(from)
        let toWords = tokenize(to)
        guard (1...2).contains(fromWords.count), (1...3).contains(toWords.count) else { return false }

        // Looks like a name: two or more capitalised words, or an internal
        // capital. A single leading capital is not enough — that is just a
        // sentence starting, and accepting it would learn "test" -> "Test".
        let looksLikeName = (toWords.count >= 2 && toWords.allSatisfy { $0.first?.isUppercase == true })
            || hasDistinctiveCapitalization(to)
        guard looksLikeName else { return false }

        let a = from.lowercased().filter { !$0.isWhitespace }
        let b = to.lowercased().filter { !$0.isWhitespace }
        // Identical but for spacing and case: that is the case-only rule's
        // business, and it has its own stricter guard.
        guard a != b else { return hasDistinctiveCapitalization(to) }

        let distance = levenshtein(a, b)
        let longest = max(a.count, b.count)
        guard longest > 0 else { return false }
        let similarity = 1.0 - Double(distance) / Double(longest)
        return similarity >= 0.55
    }

    /// True when the user did not respell a word but *completed* it: the
    /// transcriber heard "Haven" and the brand is "Hoop Haven".
    ///
    /// Judged separately from a respelling, because the two differ by several
    /// characters and would never pass the edit-distance budget. The guard here
    /// is shape instead of distance: the original has to survive whole inside
    /// the result, and the result has to look like a proper noun. That accepts
    /// "Haven" -> "Hoop Haven" and rejects "store" -> "big store".
    public static func isPlausibleExpansion(original: String, corrected: String) -> Bool {
        let from = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard from.count >= 3, !to.isEmpty, from.lowercased() != to.lowercased() else { return false }

        let fromWords = tokenize(from)
        let toWords = tokenize(to)
        guard !fromWords.isEmpty, toWords.count > fromWords.count else { return false }
        // One or two added words is a completed name; more is a new clause.
        guard toWords.count - fromWords.count <= 2 else { return false }

        // The heard word has to still be there, as a whole word.
        let escaped = fromWords
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "\\s+")
        let pattern = "(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(to.startIndex..<to.endIndex, in: to)
        guard regex.firstMatch(in: to, options: [], range: range) != nil else { return false }

        // Proper-noun shape. Without this, "store" -> "big store" would be
        // learned and would then rewrite every later "store".
        return toWords.allSatisfy { $0.first?.isUppercase == true }
    }

    /// True when a word's capitals cannot be explained by it starting a
    /// sentence: an internal capital ("ZenMux", "iPhone") or an acronym.
    static func hasDistinctiveCapitalization(_ word: String) -> Bool {
        // A phrase is judged word by word. Reading it as one string would treat
        // the second word's capital as an internal one, so "marque Hoop" would
        // look as distinctive as "ZenMux".
        let words = tokenize(word)
        if words.count > 1 {
            return words.allSatisfy { $0.first?.isUppercase == true }
        }

        let characters = Array(words.first ?? word)
        guard characters.count >= 2 else { return false }
        if characters.dropFirst().contains(where: \.isUppercase) { return true }
        let letters = characters.filter(\.isLetter)
        return !letters.isEmpty && letters.allSatisfy(\.isUppercase)
    }

    /// The corrections implied by turning `pasted` into `edited`.
    ///
    /// Returns nothing when the text was reworked rather than corrected: a
    /// handful of word swaps inside otherwise untouched text is a correction,
    /// a rewritten paragraph is not.
    public static func corrections(from pasted: String, to edited: String) -> [WordCorrection] {
        let before = tokenize(pasted)
        let after = tokenize(edited)

        guard !before.isEmpty, !after.isEmpty else { return [] }
        // The edit has to still be recognisably the same text.
        guard abs(before.count - after.count) <= 2 else { return [] }

        let substitutions = alignedSubstitutions(before, after)
        guard !substitutions.isEmpty else { return [] }
        // More than a few swaps means a rewrite, not a fix.
        guard substitutions.count <= 3 else { return [] }
        guard Double(substitutions.count) / Double(before.count) <= 0.34 else { return [] }

        var seen = Set<String>()
        var result: [WordCorrection] = []
        for (from, to) in substitutions {
            guard isPlausibleCorrection(original: from, corrected: to)
                || isPlausibleExpansion(original: from, corrected: to)
                || isPlausibleProperNounRespelling(original: from, corrected: to) else { continue }
            let key = from.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(WordCorrection(original: from, corrected: to))
        }
        return result
    }

    /// Words, keeping the characters that belong inside one: apostrophes and
    /// hyphens, so "l'entreprise" and "e-mail" stay single tokens.
    public static func tokenize(_ text: String) -> [String] {
        text.split { character in
            !(character.isLetter || character.isNumber || character == "'" || character == "’" || character == "-")
        }.map(String.init)
    }

    /// Replacement runs between the two token lists, found by walking their
    /// longest common subsequence.
    ///
    /// Runs rather than single words, because the brand-name case is usually a
    /// merge: the model hears "Zen mux" and the user types "ZenMux".
    private static func alignedSubstitutions(_ before: [String], _ after: [String]) -> [(String, String)] {
        let a = before.map { $0.lowercased() }
        let b = after.map { $0.lowercased() }

        // Standard LCS table; both sides are a sentence or two, so this is tiny.
        var lengths = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lengths[i][j] = a[i] == b[j]
                    ? lengths[i + 1][j + 1] + 1
                    : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }

        var substitutions: [(String, String)] = []
        var pendingBefore: [String] = []
        var pendingAfter: [String] = []
        var lastMatchedBefore: String?

        /// `nextMatched` is the token that is about to line up again, which is
        /// what a word inserted in front of it belongs to.
        func flush(nextMatched: String?) {
            defer {
                pendingBefore.removeAll()
                pendingAfter.removeAll()
            }

            if !pendingBefore.isEmpty, !pendingAfter.isEmpty {
                // A long run on either side is a rewritten clause.
                guard pendingBefore.count <= 3, pendingAfter.count <= 2 else { return }
                substitutions.append(
                    (pendingBefore.joined(separator: " "), pendingAfter.joined(separator: " "))
                )
                return
            }

            // A pure insertion. Usually the user adding words, but it is also
            // how a multi-word name gets completed: the transcriber heard
            // "Haven" and they typed "Hoop" in front of it. Attach the run to
            // the neighbouring word and let the plausibility rules decide.
            guard pendingBefore.isEmpty, !pendingAfter.isEmpty else { return }
            guard pendingAfter.count <= 2 else { return }
            let inserted = pendingAfter.joined(separator: " ")

            if let nextMatched {
                substitutions.append((nextMatched, inserted + " " + nextMatched))
            }
            if let lastMatchedBefore {
                substitutions.append((lastMatchedBefore, lastMatchedBefore + " " + inserted))
            }
        }

        var i = 0
        var j = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] {
                flush(nextMatched: before[i])
                lastMatchedBefore = before[i]
                // Same word, different capitals: invisible to the lowercased
                // alignment above, and the most common brand-name fix.
                if before[i] != after[j] {
                    substitutions.append((before[i], after[j]))
                }
                i += 1
                j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                pendingBefore.append(before[i])
                i += 1
            } else {
                pendingAfter.append(after[j])
                j += 1
            }
        }
        while i < a.count {
            pendingBefore.append(before[i])
            i += 1
        }
        while j < b.count {
            pendingAfter.append(after[j])
            j += 1
        }
        flush(nextMatched: nil)

        return substitutions
    }

    static func levenshtein(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs)
        let b = Array(rhs)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}

/// The learned dictionary: what to store, and how it rewrites a transcript.
public enum LearnedCorrectionStore {
    /// Kept small so the cleanup prompt does not balloon and so a stale rule
    /// eventually falls out.
    public static let maximumCount = 100

    /// Adds or refreshes `correction`, newest first, dropping the least
    /// recently seen entry once the list is full.
    public static func merging(
        _ correction: WordCorrection,
        into existing: [WordCorrection],
        now: Date = Date()
    ) -> [WordCorrection] {
        var result = existing
        if let index = result.firstIndex(where: { $0.id == correction.id }) {
            let previous = result[index]
            result[index] = WordCorrection(
                original: previous.original,
                // A newer spelling wins: the user corrected it again.
                corrected: correction.corrected,
                occurrences: previous.occurrences + 1,
                lastSeen: now
            )
        } else {
            result.append(
                WordCorrection(
                    original: correction.original,
                    corrected: correction.corrected,
                    occurrences: 1,
                    lastSeen: now
                )
            )
        }

        result.sort { $0.lastSeen > $1.lastSeen }
        if result.count > maximumCount {
            result = Array(result.prefix(maximumCount))
        }
        return result
    }

    /// One canonical spelling and every heard form that maps onto it.
    ///
    /// The stored list stays flat — one rule per heard form — so several rules
    /// sharing a spelling is exactly how "many inputs, one output" is
    /// represented. Grouping happens for display and editing only.
    public struct Group: Identifiable, Equatable {
        public let corrected: String
        public let variants: [WordCorrection]

        public var id: String { corrected.lowercased() }
    }

    public static func grouped(_ corrections: [WordCorrection]) -> [Group] {
        var order: [String] = []
        var buckets: [String: [WordCorrection]] = [:]

        for correction in corrections {
            let key = correction.corrected.lowercased()
            if buckets[key] == nil {
                buckets[key] = []
                order.append(key)
            }
            buckets[key]?.append(correction)
        }

        return order.compactMap { key in
            guard let variants = buckets[key], let first = variants.first else { return nil }
            return Group(corrected: first.corrected, variants: variants)
        }
    }

    /// Renames the spelling every variant in a group maps to.
    public static func renamingCorrected(
        from oldValue: String,
        to newValue: String,
        in corrections: [WordCorrection]
    ) -> [WordCorrection] {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return corrections }
        let key = oldValue.lowercased()

        return corrections.compactMap { correction in
            guard correction.corrected.lowercased() == key else { return correction }
            // A variant that now equals its own spelling exactly is a no-op.
            // Compared exactly, not case-insensitively: "zenmux" -> "ZenMux"
            // is a real rule, and the most common kind.
            guard correction.original != trimmed else { return nil }
            return WordCorrection(
                original: correction.original,
                corrected: trimmed,
                occurrences: correction.occurrences,
                lastSeen: correction.lastSeen
            )
        }
    }

    /// Changes one heard form, keeping the spelling it maps to.
    public static func replacingVariant(
        id: String,
        with newOriginal: String,
        in corrections: [WordCorrection]
    ) -> [WordCorrection] {
        let trimmed = newOriginal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return corrections }
        guard let existing = corrections.first(where: { $0.id == id }) else { return corrections }
        guard trimmed != existing.corrected else { return corrections }
        // Another rule already claims this heard form.
        if corrections.contains(where: { $0.id != id && $0.id == trimmed.lowercased() }) {
            return corrections
        }

        return corrections.map { correction in
            guard correction.id == id else { return correction }
            return WordCorrection(
                original: trimmed,
                corrected: correction.corrected,
                occurrences: correction.occurrences,
                lastSeen: correction.lastSeen
            )
        }
    }

    /// Adds another heard form for an existing spelling.
    public static func addingVariant(
        _ original: String,
        correctedTo corrected: String,
        in corrections: [WordCorrection],
        now: Date = Date()
    ) -> [WordCorrection] {
        let trimmedOriginal = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCorrected = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOriginal.isEmpty, !trimmedCorrected.isEmpty else { return corrections }
        guard trimmedOriginal != trimmedCorrected else { return corrections }

        return merging(
            WordCorrection(original: trimmedOriginal, corrected: trimmedCorrected),
            into: corrections,
            now: now
        )
    }

    public static func removingVariant(id: String, in corrections: [WordCorrection]) -> [WordCorrection] {
        corrections.filter { $0.id != id }
    }

    public static func removingGroup(corrected: String, in corrections: [WordCorrection]) -> [WordCorrection] {
        let key = corrected.lowercased()
        return corrections.filter { $0.corrected.lowercased() != key }
    }

    /// Rewrites `text` with every learned correction, matching whole words
    /// case-insensitively and writing the spelling the user chose.
    ///
    /// Applied deterministically rather than left to the model, so the fix also
    /// works when cleanup is turned off.
    public static func applying(_ corrections: [WordCorrection], to text: String) -> String {
        guard !corrections.isEmpty, !text.isEmpty else { return text }

        var result = text
        for correction in corrections {
            // A learned phrase ("zen mux") must still match however the
            // transcript spaced it.
            let escaped = correction.original
                .split(separator: " ")
                .map { NSRegularExpression.escapedPattern(for: String($0)) }
                .joined(separator: "\\s+")
            // Word boundaries that also respect accented letters, which \b does
            // not handle the way this needs.
            let pattern = "(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ) else { continue }

            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: correction.corrected)
            )
        }
        return result
    }
}
