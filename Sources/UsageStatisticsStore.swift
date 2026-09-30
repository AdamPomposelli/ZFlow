import Foundation

/// Where the usage counts live: one small JSON file beside the rest of the
/// app's data, owner-readable only, and never sent anywhere.
final class UsageStatisticsStore {
    static let shared = UsageStatisticsStore()

    private let queue = DispatchQueue(label: "com.zippy.zflow.usagestats")
    private var cached: UsageStatistics?

    private var fileURL: URL {
        AppState.applicationSupportDirectory().appendingPathComponent("usage-statistics.json")
    }

    func load() -> UsageStatistics {
        queue.sync {
            if let cached { return cached }
            guard let data = try? Data(contentsOf: fileURL),
                  let stats = try? JSONDecoder().decode(UsageStatistics.self, from: data) else {
                let empty = UsageStatistics()
                cached = empty
                return empty
            }
            cached = stats
            return stats
        }
    }

    func update(_ transform: (UsageStatistics) -> UsageStatistics) {
        queue.sync {
            let current = cached ?? (try? JSONDecoder().decode(
                UsageStatistics.self,
                from: (try? Data(contentsOf: fileURL)) ?? Data()
            )) ?? UsageStatistics()
            let next = transform(current)
            cached = next
            guard let data = try? JSONEncoder().encode(next) else { return }
            let url = fileURL
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        }
    }

    /// Wipes the counts. Offered because they are the user's own record of
    /// themselves, and deleting your own record should not require deleting
    /// the app.
    func reset() {
        queue.sync {
            cached = UsageStatistics()
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
}
