import Foundation

/// The loopback bridge between the settings window and the app.
///
/// Every failure here is silent in the product: a toggle that writes a key
/// the app refuses just does nothing, and a refusal that travels as an HTTP
/// error surfaces as an exception in the window. So the rules are pinned
/// here, and so is the contract with the window's own schema.
enum SettingsBridgeTests {
    static func run() {
        requestsWithoutTheTokenAreRefused()
        onlyListedKeysCanBeWritten()
        unknownRoutesAreNotFound()
        aRefusedPermissionIsAnAnswerNotAFailure()
        permissionsAreReportedThroughTheHandler()
        anIncompleteRequestWaitsForItsBody()
        queryStringsAreDecoded()
        secretsAreNeverReadBack()
        everySettingTheWindowWritesIsAccepted()
        theWindowReadsThePermissionStatesTheAppSends()
    }

    // MARK: - Requests

    private static let token = "synthetic-test-token"

    private static func request(
        _ method: String,
        _ target: String,
        token: String? = SettingsBridgeTests.token,
        json: [String: Any]? = nil
    ) -> Data {
        let body = json.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        var head = "\(method) \(target) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
        if let token { head += "Authorization: Bearer \(token)\r\n" }
        head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n"
        return Data(head.utf8) + body
    }

    private struct Reply {
        let status: Int
        let json: [String: Any]
    }

    private static func send(_ server: SettingsBridgeServer, _ raw: Data) -> Reply {
        guard let data = server.respond(toRaw: raw),
              let separator = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<separator.lowerBound], encoding: .utf8),
              let status = Int(head.split(separator: " ").dropFirst().first ?? "")
        else {
            TestSupport.expect(false, "the bridge did not answer a complete request")
            return Reply(status: 0, json: [:])
        }
        let json = (try? JSONSerialization.jsonObject(with: data[separator.upperBound...])) as? [String: Any]
        return Reply(status: status, json: json ?? [:])
    }

    private static func makeServer() -> SettingsBridgeServer {
        SettingsBridgeServer(tokenForTesting: token)
    }

    private static func requestsWithoutTheTokenAreRefused() {
        let server = makeServer()
        TestSupport.expectEqual(send(server, request("GET", "/settings", token: nil)).status, 401)
        TestSupport.expectEqual(send(server, request("GET", "/settings", token: "wrong")).status, 401)
        TestSupport.expectEqual(send(server, request("GET", "/settings")).status, 200)

        // A server whose token was never set refuses even an empty bearer.
        let unset = SettingsBridgeServer(tokenForTesting: "")
        TestSupport.expectEqual(send(unset, request("GET", "/settings", token: "")).status, 401)
    }

    private static func onlyListedKeysCanBeWritten() {
        let server = makeServer()
        var written: [String] = []
        server.writeHandler = { key, _ in written.append(key); return true }

        let refused = send(server, request("POST", "/settings", json: ["key": "not_a_setting", "value": true]))
        TestSupport.expectEqual(refused.status, 403)
        TestSupport.expect(written.isEmpty, "a key outside the contract reached the app")

        let accepted = send(server, request("POST", "/settings", json: ["key": "show_app_in_dock", "value": false]))
        TestSupport.expectEqual(accepted.status, 200)
        TestSupport.expectEqual(written, ["show_app_in_dock"])
    }

    private static func unknownRoutesAreNotFound() {
        TestSupport.expectEqual(send(makeServer(), request("GET", "/nowhere")).status, 404)
    }

    /// The regression: an unknown permission came back as 422, which the
    /// window's HTTP helper turns into an exception, and the Grant button
    /// stayed stuck on "Waiting…".
    private static func aRefusedPermissionIsAnAnswerNotAFailure() {
        let server = makeServer()
        server.permissionRequestHandler = { _ in false }
        let reply = send(server, request("POST", "/permissions/request", json: ["access": "nonsense"]))
        TestSupport.expectEqual(reply.status, 200)
        TestSupport.expectEqual(reply.json["ok"] as? Bool, false)

        let malformed = send(server, request("POST", "/permissions/request", json: [:]))
        TestSupport.expectEqual(malformed.status, 400)
    }

    private static func permissionsAreReportedThroughTheHandler() {
        let server = makeServer()
        let items = PermissionsCore.items(
            microphoneGranted: true,
            accessibilityGranted: false,
            screenRecordingGranted: false,
            screenRecordingNeeded: false
        )
        server.permissionsHandler = {
            [
                "items": items.map { ["access": $0.access.rawValue, "state": $0.state.rawValue] },
                "outstanding": PermissionsCore.outstandingCount(items),
            ]
        }
        let reply = send(server, request("GET", "/permissions"))
        TestSupport.expectEqual(reply.status, 200)
        TestSupport.expectEqual(reply.json["outstanding"] as? Int, 1)
        TestSupport.expectEqual((reply.json["items"] as? [Any])?.count, 3)
    }

    private static func anIncompleteRequestWaitsForItsBody() {
        let full = request("POST", "/settings", json: ["key": "show_app_in_dock", "value": true])
        let server = makeServer()
        TestSupport.expect(
            server.respond(toRaw: full.prefix(full.count - 3)) == nil,
            "a request whose body has not fully arrived must not be answered yet"
        )
        TestSupport.expect(
            server.respond(toRaw: Data("GET /settings HTTP/1.1\r\nHost: x\r\n".utf8)) == nil,
            "a request without the end of its headers must not be answered yet"
        )
    }

    private static func queryStringsAreDecoded() {
        let server = makeServer()
        var asked: String?
        server.screenshotHandler = { id in asked = id; return "data:image/jpeg;base64,AAAA" }
        let reply = send(server, request("GET", "/screenshot?id=A%20B"))
        TestSupport.expectEqual(reply.status, 200)
        TestSupport.expectEqual(asked, "A B")
    }

    /// Credentials can be set from the window and never read back out.
    private static func secretsAreNeverReadBack() {
        let server = makeServer()
        server.readHandler = { key in
            SettingsBridgeContract.secretKeys.contains(key) ? "set" : nil
        }
        let reply = send(server, request("GET", "/settings"))
        for key in SettingsBridgeContract.secretKeys {
            let value = reply.json[key] as? String
            TestSupport.expect(value == nil || value == "set", "\(key) was read back as a value")
        }
    }

    // MARK: - The contract with the settings window

    private static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func source(_ path: String) -> String {
        let url = repository.appendingPathComponent(path)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            TestSupport.expect(false, "could not read \(path)")
            return ""
        }
        return text
    }

    private static func literals(_ pattern: String, in text: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var found: Set<String> = []
        for match in regex.matches(in: text, range: range) {
            guard let r = Range(match.range(at: 1), in: text) else { continue }
            found.insert(String(text[r]))
        }
        return found
    }

    /// Every key the window can write must be one the app accepts, and one
    /// it reports back — otherwise the control on screen does nothing and
    /// says nothing.
    private static func everySettingTheWindowWritesIsAccepted() {
        let schema = source("electron/src/settings-schema.ts")
        let app = source("electron/src/App.tsx")

        var written = literals(#"\bkey:\s*"([a-z0-9_]+)""#, in: schema)
        // cascadeOff: ["a", "b"] — every key it names is written as false.
        for list in literals(#"cascadeOff:\s*\[([^\]]*)\]"#, in: schema) {
            written.formUnion(literals(#""([a-z0-9_]+)""#, in: list))
        }
        // PIPELINE_KEYS = { cleanup: "post_processing_enabled", ... }
        for block in literals(#"PIPELINE_KEYS\s*=\s*\{([^}]*)\}"#, in: schema) {
            written.formUnion(literals(#":\s*"([a-z0-9_]+)""#, in: block))
        }
        written.formUnion(literals(#"write\(\s*"([a-z0-9_]+)""#, in: app))

        // Guards the guard: a pattern that silently matched nothing would
        // make everything below pass.
        TestSupport.expect(written.count >= 20, "found only \(written.count) keys in the window's schema")

        let accepted = SettingsBridgeContract.allWritable
        let readable = Set(SettingsBridgeContract.readableKeys)
        for key in written.sorted() {
            TestSupport.expect(accepted.contains(key), "the window writes \(key), which the app refuses")
            TestSupport.expect(readable.contains(key), "the window writes \(key), which the app never reports back")
        }

        // Conditions and badges read keys: those have to be reported too.
        let read = literals(#"when:\s*\{\s*key:\s*"([a-z0-9_]+)""#, in: schema)
            .union(literals(#"badgeKey:\s*"([a-z0-9_]+)""#, in: schema))
        for key in read.sorted() {
            TestSupport.expect(readable.contains(key), "the window reads \(key), which the app never reports")
        }
    }

    /// The window switches on the exact words the app sends for each state.
    private static func theWindowReadsThePermissionStatesTheAppSends() {
        let component = source("electron/src/components/Permissions.tsx")
        // Handled means compared against, not merely named: the type
        // declaration lists every state whether or not anything draws it.
        let handled = literals(#"state\s*===\s*"([a-z_]+)""#, in: component)
        for state in [PermissionsCore.State.granted, .missing, .notNeeded] {
            TestSupport.expect(
                handled.contains(state.rawValue),
                "the settings window does not handle the permission state \(state.rawValue)"
            )
        }
        for access in PermissionsCore.Access.allCases {
            TestSupport.expect(
                component.contains(access.rawValue),
                "the settings window has no glyph for \(access.rawValue)"
            )
        }
    }
}
