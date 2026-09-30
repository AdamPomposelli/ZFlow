import Foundation

/// Where meetings live: one folder per note, holding its two audio tracks and
/// a small JSON file describing it.
///
/// On disk rather than in UserDefaults because a meeting carries audio, and
/// beside the rest of ZFlow's data rather than anywhere else because it is the
/// most sensitive thing this app holds — a recording of a conversation. Owner
/// only, and nothing is uploaded except by the engine the user chose.
final class NotetakerStore {
    static let shared = NotetakerStore()

    private let queue = DispatchQueue(label: "com.zippy.zflow.notetaker")

    var rootDirectory: URL {
        AppState.applicationSupportDirectory().appendingPathComponent("Meetings", isDirectory: true)
    }

    func directory(for id: String) -> URL? {
        guard NotetakerCore.isValidIdentifier(id) else { return nil }
        return rootDirectory.appendingPathComponent(id, isDirectory: true)
    }

    /// Makes an empty note and the folder its audio will be written into.
    func create(startedAt: Date = Date()) -> MeetingNote? {
        let id = NotetakerCore.newIdentifier()
        guard let folder = directory(for: id) else { return nil }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: folder.path
            )
        } catch {
            return nil
        }
        let note = MeetingNote(
            id: id,
            title: NotetakerCore.defaultTitle(startedAt: startedAt),
            startedAt: startedAt
        )
        save(note)
        return note
    }

    func save(_ note: MeetingNote) {
        queue.sync {
            guard let folder = directory(for: note.id) else { return }
            let url = folder.appendingPathComponent("note.json")
            guard let data = try? JSONEncoder().encode(note) else { return }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    func load(_ id: String) -> MeetingNote? {
        queue.sync {
            guard let folder = directory(for: id) else { return nil }
            let url = folder.appendingPathComponent("note.json")
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(MeetingNote.self, from: data)
        }
    }

    /// Newest first. A folder without a readable note.json is skipped rather
    /// than failing the whole list.
    func all() -> [MeetingNote] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        return folders
            .compactMap { load($0.lastPathComponent) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    func trackURL(for id: String, named name: String) -> URL? {
        guard name == NotetakerCore.micTrackFileName || name == NotetakerCore.systemTrackFileName else {
            return nil
        }
        return directory(for: id)?.appendingPathComponent(name)
    }

    /// Removes the note and everything recorded with it.
    @discardableResult
    func delete(_ id: String) -> Bool {
        guard let folder = directory(for: id) else { return false }
        do {
            try FileManager.default.removeItem(at: folder)
            return true
        } catch {
            return false
        }
    }

    func payload(_ note: MeetingNote) -> [String: Any] {
        [
            "id": note.id,
            "title": note.title,
            "startedAt": AppState.bridgeDateFormatter.string(from: note.startedAt),
            "durationSeconds": note.durationSeconds,
            "state": note.state.rawValue,
            "transcript": note.transcript,
            "summary": note.summary,
            "speakers": note.speakers,
            "engine": note.engine,
            "error": note.errorMessage,
            "segments": note.segments.map { segment in
                [
                    "speaker": segment.speaker,
                    "text": segment.text,
                    "start": segment.start,
                    "end": segment.end
                ] as [String: Any]
            }
        ]
    }
}
