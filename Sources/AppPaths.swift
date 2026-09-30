import Foundation

/// Where ZFlow keeps its own files.
///
/// Its own file so that anything needing the location — the settings bridge
/// writing its handshake, say — does not have to depend on `AppState` to get
/// it, and can be compiled and tested on its own.
enum AppPaths {
    static func applicationSupportDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = appSupport.appendingPathComponent(AppName.displayName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }
}
