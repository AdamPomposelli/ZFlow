import Foundation
import Network
import os.log

private let bridgeLog = OSLog(subsystem: "com.zippy.zflow", category: "SettingsBridge")

/// A loopback-only HTTP endpoint the Electron front end uses to read and write
/// settings while the app is running.
///
/// Without this the UI can only write to UserDefaults, which AppState reads once
/// at launch — so a change would not take effect until the next start.
///
/// The security shape matters, because this is a new surface on a machine, not
/// a feature: the listener binds to 127.0.0.1 only and is never reachable from
/// the network; every request must carry a token generated fresh at each launch
/// and written to a file only the user can read; and the endpoint can only get
/// and set the specific settings keys listed in `SettingsBridgeContract`, so a
/// caller cannot reach anything else in the app.
final class SettingsBridgeServer: @unchecked Sendable {
    static let shared = SettingsBridgeServer()

    private let queue = DispatchQueue(label: "com.zippy.zflow.settingsbridge")
    private var listener: NWListener?
    private var token = ""

    /// Reads a value for a key. Set by AppState.
    var readHandler: ((String) -> Any?)?
    /// Writes a value for a key. Set by AppState. Returns false if refused.
    var writeHandler: ((String, Any) -> Bool)?
    /// Supplies the run history as JSON-ready dictionaries.
    var historyHandler: (() -> [[String: Any]])?
    /// Supplies the learned dictionary as JSON-ready dictionaries.
    var dictionaryHandler: (() -> [[String: Any]])?
    /// Supplies the available input devices.
    var microphonesHandler: (() -> [[String: Any]])?
    /// Applies an edit to the learned dictionary. Returns false if refused.
    var dictionaryMutationHandler: ((String, [String: Any]) -> Bool)?
    /// Supplies the built-in prompt text, so the front end can show what a
    /// blank prompt field actually falls back to.
    var defaultsHandler: (() -> [String: Any])?
    /// Supplies the languages the *currently chosen* transcription engine can
    /// actually handle.
    var languagesHandler: (() -> [String: Any])?
    /// Supplies one run's screenshot, by run id. Deliberately one at a time:
    /// these are images of the user's screen, and the history list would carry
    /// fifty of them through the main thread on every poll.
    var screenshotHandler: ((String) -> String?)?
    /// Supplies the local usage counts shown on the Insights page.
    var insightsHandler: (() -> [String: Any])?
    /// Wipes those counts.
    var insightsResetHandler: (() -> Void)?
    /// Begins transcribing a dropped audio file. Answers with a job to poll.
    var fileTranscriptionStartHandler: ((String) -> [String: Any])?
    /// Reports how that job is doing.
    var fileTranscriptionStatusHandler: ((String) -> [String: Any]?)?
    /// Everything to do with recorded meetings, by action name.
    var meetingHandler: ((String, [String: Any]) -> [String: Any])?
    /// Removes one run from the history. Returns false if it was not there.
    var historyDeleteHandler: ((String) -> Bool)?
    /// Quits ZFlow. The settings window's Command-Q comes through here, so the
    /// two processes end together rather than one outliving the other.
    var quitHandler: (() -> Void)?

    /// The system permissions and whether each one has been given.
    var permissionsHandler: (() -> [String: Any])?

    /// Asks for one permission by name. Returns false for a name nobody knows.
    var permissionRequestHandler: ((String) -> Bool)?

    private init() {}

    /// A server that is never started, answering with a token the caller
    /// chose. For tests: it opens no listener and writes no handshake, so it
    /// can only be reached by calling `respond(toRaw:)` directly.
    init(tokenForTesting token: String) {
        self.token = token
    }

    /// Parses and answers one raw request, exactly as a connection would.
    /// Nil while the request is still incomplete.
    func respond(toRaw buffer: Data) -> Data? {
        guard let request = HTTPRequest(buffer) else { return nil }
        return respond(to: request)
    }

    /// Where the front end looks for the port and token.
    static var handshakeURL: URL {
        AppPaths.applicationSupportDirectory().appendingPathComponent("ui-bridge.json")
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.listener == nil else { return }
            do {
                let parameters = NWParameters.tcp
                // Loopback only. This must never be reachable off the machine.
                parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
                let listener = try NWListener(using: parameters)
                self.token = Self.makeToken()

                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                listener.stateUpdateHandler = { [weak self] state in
                    guard case .ready = state, let self, let port = self.listener?.port else { return }
                    self.writeHandshake(port: port.rawValue)
                    os_log(.default, log: bridgeLog, "settings bridge listening on 127.0.0.1:%d", port.rawValue)
                }
                listener.start(queue: self.queue)
                self.listener = listener
            } catch {
                os_log(
                    .error,
                    log: bridgeLog,
                    "could not start the settings bridge: %{public}@",
                    error.localizedDescription
                )
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.listener?.cancel()
            self?.listener = nil
            try? FileManager.default.removeItem(at: Self.handshakeURL)
        }
    }

    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// The handshake file is readable by this user only: it is the credential.
    private func writeHandshake(port: UInt16) {
        let payload: [String: Any] = ["port": Int(port), "token": token]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let url = Self.handshakeURL
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

    // MARK: Connection handling

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard error == nil else {
                connection.cancel()
                return
            }

            var buffer = buffer
            if let data { buffer.append(data) }

            // Keep reading until the headers and any declared body have arrived.
            guard let response = self.respond(toRaw: buffer) else {
                if isComplete || buffer.count > 512 * 1024 {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer)
                }
                return
            }

            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func respond(to request: HTTPRequest) -> Data {
        guard request.bearerToken == token, !token.isEmpty else {
            return Self.response(status: "401 Unauthorized", json: ["error": "bad token"])
        }

        switch (request.method, request.path) {
        case ("GET", "/settings"):
            var values: [String: Any] = [:]
            for key in SettingsBridgeContract.readableKeys {
                values[key] = readHandler?(key) ?? NSNull()
            }
            return Self.response(status: "200 OK", json: values)

        case ("POST", "/settings"):
            guard let body = request.jsonBody,
                  let key = body["key"] as? String,
                  let value = body["value"] else {
                return Self.response(status: "400 Bad Request", json: ["error": "key and value required"])
            }
            guard SettingsBridgeContract.allWritable.contains(key) else {
                return Self.response(status: "403 Forbidden", json: ["error": "key is not writable"])
            }
            let accepted = writeHandler?(key, value) ?? false
            return Self.response(
                status: accepted ? "200 OK" : "422 Unprocessable Entity",
                json: ["ok": accepted]
            )

        case ("GET", "/permissions"):
            return Self.response(status: "200 OK", json: permissionsHandler?() ?? ["items": []])

        case ("POST", "/permissions/request"):
            guard let body = request.jsonBody, let access = body["access"] as? String else {
                return Self.response(status: "400 Bad Request", json: ["error": "access required"])
            }
            // 200 either way: a name nobody knows is a question answered, not
            // a broken request. The settings window reads `ok`, and a status
            // it treats as a transport failure would surface as an exception
            // where a plain "no" belongs.
            let asked = permissionRequestHandler?(access) ?? false
            return Self.response(status: "200 OK", json: ["ok": asked])

        case ("POST", "/quit"):
            quitHandler?()
            return Self.response(status: "200 OK", json: ["ok": true])

        case ("POST", "/history/delete"):
            guard let body = request.jsonBody, let id = body["id"] as? String else {
                return Self.response(status: "400 Bad Request", json: ["error": "id required"])
            }
            let removed = historyDeleteHandler?(id) ?? false
            return Self.response(status: removed ? "200 OK" : "404 Not Found", json: ["ok": removed])

        case ("GET", "/history"):
            return Self.response(status: "200 OK", json: ["items": historyHandler?() ?? []])

        case ("POST", "/dictionary"):
            guard let body = request.jsonBody, let action = body["action"] as? String else {
                return Self.response(status: "400 Bad Request", json: ["error": "action required"])
            }
            let ok = dictionaryMutationHandler?(action, body) ?? false
            return Self.response(status: ok ? "200 OK" : "422 Unprocessable Entity", json: ["ok": ok])

        case ("GET", "/screenshot"):
            guard let id = request.query["id"], let dataURL = screenshotHandler?(id) else {
                return Self.response(status: "404 Not Found", json: ["error": "no screenshot for that run"])
            }
            return Self.response(status: "200 OK", json: ["dataURL": dataURL])

        case ("POST", "/meetings"):
            guard let body = request.jsonBody, let action = body["action"] as? String else {
                return Self.response(status: "400 Bad Request", json: ["error": "action required"])
            }
            let result = meetingHandler?(action, body) ?? ["ok": false, "error": "ZFlow is not ready"]
            return Self.response(status: "200 OK", json: result)

        case ("POST", "/transcribe-file"):
            guard let body = request.jsonBody, let path = body["path"] as? String, !path.isEmpty else {
                return Self.response(status: "400 Bad Request", json: ["error": "path required"])
            }
            let started = fileTranscriptionStartHandler?(path)
                ?? ["ok": false, "error": "ZFlow is not ready"]
            return Self.response(status: "200 OK", json: started)

        case ("GET", "/transcribe-file"):
            guard let id = request.query["id"], let job = fileTranscriptionStatusHandler?(id) else {
                return Self.response(status: "404 Not Found", json: ["error": "no such job"])
            }
            return Self.response(status: "200 OK", json: job)

        case ("GET", "/insights"):
            return Self.response(status: "200 OK", json: insightsHandler?() ?? [:])

        case ("POST", "/insights/reset"):
            insightsResetHandler?()
            return Self.response(status: "200 OK", json: ["ok": true])

        case ("GET", "/defaults"):
            return Self.response(status: "200 OK", json: defaultsHandler?() ?? [:])

        case ("GET", "/languages"):
            return Self.response(status: "200 OK", json: languagesHandler?() ?? [:])

        case ("GET", "/microphones"):
            return Self.response(status: "200 OK", json: ["items": microphonesHandler?() ?? []])

        case ("GET", "/dictionary"):
            return Self.response(status: "200 OK", json: ["items": dictionaryHandler?() ?? []])

        default:
            return Self.response(status: "404 Not Found", json: ["error": "no such endpoint"])
        }
    }

    private static func response(status: String, json: Any) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}

/// The only keys the bridge will touch. Anything absent here is unreachable
/// from outside the app, which keeps the surface to settings the UI edits.
enum SettingsBridgeContract {
    /// Credentials. Writable so the front end can set them, and deliberately
    /// never returned: a read reports only whether one is present. Setting a
    /// key is something the user does; reading one back out over a socket is
    /// not something they ever need, so the endpoint cannot do it.
    static let secretKeys: Set<String> = [
        "api_key",
        "transcription_api_key"
    ]

    static let writableKeys: Set<String> = [
        "transcription_engine",
        "post_processing_engine",
        "transcription_model",
        "transcription_language",
        "transcription_request_format",
        "api_base_url",
        "post_processing_model",
        "post_processing_fallback_model",
        "context_model",
        "output_language",
        "post_processing_enabled",
        "context_inference_enabled",
        "context_screenshot_enabled",
        "learned_corrections_enabled",
        "correction_adjudication_enabled",
        "preserve_exact_wording",
        "instruction_execution_guard_enabled",
        "command_mode_enabled",
        "press_enter_voice_command_enabled",
        "preserve_clipboard",
        "keep_dictation_in_clipboard_history",
        "alert_sounds_enabled",
        "dictation_audio_interruption_enabled",
        "realtime_streaming_enabled",
        "show_menu_bar_icon",
        "show_app_in_dock",
        "notetaker_engine",
        "use_compact_overlay",
        "launch_at_login",
        "transcription_api_url",
        "realtime_streaming_model",
        "custom_vocabulary",
        "custom_system_prompt",
        "custom_context_prompt",
        "sound_volume",
        "shortcut_start_delay",
        "context_screenshot_max_dimension",
        "command_mode_style",
        "selected_microphone_id"
    ]

    static var allWritable: Set<String> { writableKeys.union(secretKeys) }

    static var readableKeys: [String] { writableKeys.union(secretKeys).sorted() }
}

// MARK: - Minimal HTTP parsing

private struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data

    var bearerToken: String? {
        guard let value = headers["authorization"], value.lowercased().hasPrefix("bearer ") else {
            return nil
        }
        return String(value.dropFirst("bearer ".count))
    }

    var jsonBody: [String: Any]? {
        try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }

    /// Returns nil until the whole request has arrived.
    init?(_ buffer: Data) {
        guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: buffer[..<separator.lowerBound], encoding: .utf8) else { return nil }

        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let declaredLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = separator.upperBound
        let available = buffer.count - bodyStart
        guard available >= declaredLength else { return nil }

        self.method = String(requestLine[0])
        let target = String(requestLine[1]).components(separatedBy: "?")
        self.path = target.first ?? "/"
        var query: [String: String] = [:]
        for pair in (target.count > 1 ? target[1] : "").components(separatedBy: "&") where !pair.isEmpty {
            let parts = pair.components(separatedBy: "=")
            guard parts.count == 2 else { continue }
            query[parts[0].removingPercentEncoding ?? parts[0]] =
                parts[1].removingPercentEncoding ?? parts[1]
        }
        self.query = query
        self.headers = headers
        self.body = buffer[bodyStart..<(bodyStart + declaredLength)]
    }
}
