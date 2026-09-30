import Foundation

/// Whether the on-device speech model can be used right now, or has to be
/// fetched first.
///
/// Pure, so it can be tested without a Mac's speech service agreeing to
/// anything. The caller asks the system and hands the answers in.
///
/// The question is "is the model on this disk", answered by the list of
/// installed locales. It is not `AssetInventory.status`: that reports
/// `.installed` only while this app holds a reservation for the locale, and
/// the reservation lives in Apple's speech service. When macOS restarts that
/// service — idle, memory pressure, a network change — the reservation is
/// gone, the status drops to `.supported`, and a model sitting on disk and
/// transcribing perfectly well read as missing. Every dictation then failed
/// with "No on-device model" until the app was relaunched.
enum SpeechAssetGateCore {
    /// `AssetInventory.Status`, without importing Speech.
    enum Inventory: Equatable {
        case unsupported
        case supported
        case downloading
        case installed
    }

    enum Decision: Equatable {
        /// The model is here. Transcribe.
        case transcribe
        /// The model is not here, and this Mac can have it.
        case download
        /// Nothing to download: this Mac has no model for the locale.
        case unsupported
    }

    static func decision(
        locale: String,
        installedLocales: [String],
        inventory: Inventory
    ) -> Decision {
        // On disk wins over everything the inventory says. The analyzer is
        // the final judge, and it runs on what is installed.
        if installedLocales.contains(locale) { return .transcribe }

        switch inventory {
        case .installed:
            return .transcribe
        case .unsupported:
            return .unsupported
        case .supported, .downloading:
            return .download
        }
    }
}
