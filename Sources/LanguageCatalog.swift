import Foundation

/// The dictation languages an engine can actually be asked for.
///
/// ZFlow stores one short ISO 639-1 code for the dictation language, and both
/// engines have to accept it: the cloud providers take exactly that, and
/// Apple's on-device transcriber resolves it onto whichever regional locale it
/// holds. Keeping a single value space is what makes switching engines safe —
/// a code picked while on-device is still a code the provider understands, so
/// the choice does not quietly become invalid.
enum LanguageCatalog {
    struct Entry: Equatable {
        let code: String
        let name: String
        let nativeName: String
        /// On-device only: whether the model for this language is downloaded.
        let installed: Bool
    }

    /// The name of a language written in that language ("Français"), which is
    /// how someone scanning a long list finds their own.
    static func nativeName(for code: String) -> String {
        let locale = Locale(identifier: code)
        guard let name = locale.localizedString(forLanguageCode: code), !name.isEmpty else {
            return code.uppercased()
        }
        return capitalizingFirst(name)
    }

    static func englishName(for code: String, fallback: String? = nil) -> String {
        if let fallback, !fallback.isEmpty { return fallback }
        let english = Locale(identifier: "en_US")
        guard let name = english.localizedString(forLanguageCode: code), !name.isEmpty else {
            return code.uppercased()
        }
        return capitalizingFirst(name)
    }

    private static func capitalizingFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return String(first).uppercased() + text.dropFirst()
    }

    /// The cloud list: the codes ZFlow has always sent as the provider's
    /// `language` parameter.
    static func cloudEntries(from options: [(code: String, name: String)]) -> [Entry] {
        options
            .filter { !$0.code.isEmpty }
            .map { Entry(code: $0.code, name: $0.name, nativeName: nativeName(for: $0.code), installed: true) }
    }

    /// The on-device list: every language Apple's transcriber supports on this
    /// Mac, reduced to the same short codes, marked with whether the model has
    /// been downloaded already.
    static func localEntries(
        supportedLocaleIdentifiers: [String],
        installedLocaleIdentifiers: [String],
        names: [(code: String, name: String)]
    ) -> [Entry] {
        let knownNames = Dictionary(names.map { ($0.code, $0.name) }, uniquingKeysWith: { first, _ in first })
        let installedCodes = Set(installedLocaleIdentifiers.compactMap(languageCode(of:)))
        var seen = Set<String>()
        var entries: [Entry] = []
        for identifier in supportedLocaleIdentifiers {
            guard let code = languageCode(of: identifier), seen.insert(code).inserted else { continue }
            entries.append(Entry(
                code: code,
                name: englishName(for: code, fallback: knownNames[code]),
                nativeName: nativeName(for: code),
                installed: installedCodes.contains(code)
            ))
        }
        return entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// "fr-FR", "fr_FR" and "fr" all name the same choice here.
    static func languageCode(of identifier: String) -> String? {
        let head = identifier
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .first
            .map(String.init)?
            .lowercased()
        guard let head, !head.isEmpty else { return nil }
        return head
    }
}
