import Foundation

enum LanguageCatalogTests {
    static func run() {
        regionalIdentifiersCollapseToOneChoice()
        installedIsMarkedFromTheLanguageNotTheRegion()
        cloudListDropsTheAutoDetectPlaceholder()
        nativeNamesAreWrittenInTheirOwnLanguage()
        unknownCodesStillProduceAnEntry()
    }

    /// "en-US" and "en-GB" are the same pick as far as the stored code goes,
    /// so the picker must not show English twice.
    private static func regionalIdentifiersCollapseToOneChoice() {
        let entries = LanguageCatalog.localEntries(
            supportedLocaleIdentifiers: ["en-US", "en-GB", "fr-FR"],
            installedLocaleIdentifiers: [],
            names: [("en", "English"), ("fr", "French")]
        )
        TestSupport.expect(entries.map(\.code) == ["en", "fr"], "regional variants collapse, got \(entries.map(\.code))")
    }

    private static func installedIsMarkedFromTheLanguageNotTheRegion() {
        let entries = LanguageCatalog.localEntries(
            supportedLocaleIdentifiers: ["en-US", "fr-FR"],
            installedLocaleIdentifiers: ["en_GB"],
            names: []
        )
        let english = entries.first { $0.code == "en" }
        let french = entries.first { $0.code == "fr" }
        TestSupport.expect(english?.installed == true, "en-GB installed should mark English as installed")
        TestSupport.expect(french?.installed == false, "French has no downloaded model")
    }

    /// The empty code means auto-detect and is a separate control in the UI,
    /// never a row in the language grid.
    private static func cloudListDropsTheAutoDetectPlaceholder() {
        let entries = LanguageCatalog.cloudEntries(from: [("", "Auto-detect"), ("fr", "French")])
        TestSupport.expect(entries.map(\.code) == ["fr"], "auto-detect is not a language row")
    }

    private static func nativeNamesAreWrittenInTheirOwnLanguage() {
        TestSupport.expect(LanguageCatalog.nativeName(for: "fr") == "Français", "fr -> Français, got \(LanguageCatalog.nativeName(for: "fr"))")
        TestSupport.expect(LanguageCatalog.nativeName(for: "de") == "Deutsch", "de -> Deutsch, got \(LanguageCatalog.nativeName(for: "de"))")
    }

    /// A locale the system cannot name must still be offerable rather than
    /// vanishing from a list the engine says it supports.
    private static func unknownCodesStillProduceAnEntry() {
        let entries = LanguageCatalog.localEntries(
            supportedLocaleIdentifiers: ["zzz-ZZ"],
            installedLocaleIdentifiers: [],
            names: []
        )
        TestSupport.expect(entries.count == 1, "an unnameable locale is still a choice")
        TestSupport.expect(entries.first?.code == "zzz", "code survives, got \(entries.first?.code ?? "nil")")
    }
}
