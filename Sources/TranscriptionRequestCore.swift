import Foundation

/// Wire format used for the `/audio/transcriptions` request body.
///
/// OpenAI and Groq accept `multipart/form-data` with the recording in a `file`
/// part. ZenMux only accepts `application/json` with the recording base64
/// encoded inside `input_audio`, so the body has to be built differently per
/// provider. `automatic` keeps the OpenAI-compatible default and switches to
/// JSON when the transcription base URL points at a provider known to require
/// it, so pasting a ZenMux URL works without a second setting to find.
public enum TranscriptionRequestFormat: String, CaseIterable, Codable {
    case automatic
    case multipart
    case jsonBase64 = "json_base64"

    public var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .multipart: return "Multipart form-data (OpenAI, Groq)"
        case .jsonBase64: return "JSON base64 (ZenMux)"
        }
    }

    public static func normalized(_ rawValue: String?) -> TranscriptionRequestFormat {
        guard let rawValue else { return .automatic }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return TranscriptionRequestFormat(rawValue: trimmed) ?? .automatic
    }

    /// The concrete format to send, given the host the request goes to.
    /// Only `automatic` consults the host; an explicit choice always wins so a
    /// user behind a proxy or gateway can override the detection.
    public func resolved(forHost host: String?) -> ResolvedTranscriptionRequestFormat {
        switch self {
        case .multipart:
            return .multipart
        case .jsonBase64:
            return .jsonBase64
        case .automatic:
            return TranscriptionProvider.requiresJSONBase64(host: host) ? .jsonBase64 : .multipart
        }
    }
}

/// The format actually put on the wire, with `automatic` already resolved.
public enum ResolvedTranscriptionRequestFormat: String, Equatable {
    case multipart
    case jsonBase64
}

public enum TranscriptionProvider {
    /// Hosts whose transcription endpoint rejects multipart uploads.
    private static let jsonBase64Hosts: Set<String> = ["zenmux.ai"]

    public static let zenmuxBaseURL = "https://zenmux.ai/api/v1"

    public static func requiresJSONBase64(host: String?) -> Bool {
        guard let normalized = normalizedHost(host) else { return false }
        return jsonBase64Hosts.contains(where: { normalized == $0 || normalized.hasSuffix(".\($0)") })
    }

    public static func isZenMux(baseURL: String) -> Bool {
        guard let host = host(fromBaseURL: baseURL), let normalized = normalizedHost(host) else {
            return false
        }
        return normalized == "zenmux.ai" || normalized.hasSuffix(".zenmux.ai")
    }

    public static func host(fromBaseURL baseURL: String) -> String? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URLComponents(string: trimmed)?.host
    }

    private static func normalizedHost(_ host: String?) -> String? {
        guard let host else { return nil }
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}

public enum TranscriptionRequestBodyError: Error, Equatable {
    case jsonEncodingFailed
}

public enum TranscriptionRequestBody {
    /// Container formats ZenMux documents for `input_audio.format`.
    private static let knownAudioFormats: Set<String> = [
        "wav", "mp3", "flac", "m4a", "ogg", "webm", "aac"
    ]

    /// Maps a recording's file name onto the container name providers expect.
    /// Unknown extensions fall back to `wav`, which is what ZFlow records.
    public static func audioFormat(forFileName fileName: String) -> String {
        let fileExtension = (fileName as NSString).pathExtension.lowercased()
        if fileExtension == "mp4" {
            return "m4a"
        }
        return knownAudioFormats.contains(fileExtension) ? fileExtension : "wav"
    }

    public static func contentType(forFileName fileName: String) -> String {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        case "flac": return "audio/flac"
        case "ogg": return "audio/ogg"
        case "webm": return "audio/webm"
        case "aac": return "audio/aac"
        default: return "audio/mp4"
        }
    }

    public static func multipart(
        audioData: Data,
        fileName: String,
        model: String,
        responseFormat: String,
        language: String?,
        boundary: String
    ) -> Data {
        var body = Data()

        func append(_ value: String) {
            body.append(Data(value.utf8))
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        append("\(model)\r\n")

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
        append("\(responseFormat)\r\n")

        if let language, !language.isEmpty {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"language\"\r\n\r\n")
            append("\(language)\r\n")
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
        append("Content-Type: \(contentType(forFileName: fileName))\r\n\r\n")
        body.append(audioData)
        append("\r\n")
        append("--\(boundary)--\r\n")

        return body
    }

    /// ZenMux-style body: the recording is base64 encoded as a raw string (not a
    /// data URI) under `input_audio`. `response_format` is deliberately omitted
    /// because ZenMux does not accept it and always answers with `{"text": ...}`.
    public static func jsonBase64(
        audioData: Data,
        fileName: String,
        model: String,
        language: String?
    ) throws -> Data {
        var payload: [String: Any] = [
            "model": model,
            "input_audio": [
                "data": audioData.base64EncodedString(),
                "format": audioFormat(forFileName: fileName)
            ]
        ]

        if let language, !language.isEmpty {
            payload["language"] = language
        }

        do {
            return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        } catch {
            throw TranscriptionRequestBodyError.jsonEncodingFailed
        }
    }
}
