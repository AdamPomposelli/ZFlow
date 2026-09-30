import Foundation
import AVFoundation
import os.log

private let transcriptionLog = OSLog(subsystem: "com.zippy.zflow", category: "Transcription")

class TranscriptionService {
    private static let modelsSupportingVerboseJSON: Set<String> = [
        // OpenAI's Whisper model supports segment metadata. The newer
        // gpt-4o-transcribe family only supports the plain JSON format.
        "whisper-1",
        // Groq's hosted Whisper models support verbose_json and expose the
        // segment metadata used by the hallucination filter below.
        "whisper-large-v3",
        "whisper-large-v3-turbo"
    ]

    private let apiKey: String
    private let baseURL: URL
    private let transcriptionModel: String
    private let language: String?
    private let requestFormat: ResolvedTranscriptionRequestFormat
    private let uploadFormat: AudioUploadEncoder.Format
    private var transcriptionResponseFormat: String {
        Self.responseFormat(forModel: transcriptionModel)
    }
    /// Base budget before the per-second-of-audio allowance is added.
    private var transcriptionTimeoutBaseSeconds: TimeInterval {
        let override = UserDefaults.standard.double(forKey: "transcription_timeout_seconds")
        return override > 0 ? override : TranscriptionTimeoutBudget.defaultBaseSeconds
    }

    /// Measures the recording so the timeout can scale with it and so a failure
    /// can say how much audio was involved. Returns nil rather than throwing:
    /// this is diagnostic information, and an unreadable header must not stop a
    /// transcription the provider would have accepted.
    static func audioDurationSeconds(of fileURL: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: fileURL) else { return nil }
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0, file.length > 0 else { return nil }
        return Double(file.length) / sampleRate
    }

    init(
        apiKey: String,
        baseURL: String = "https://api.groq.com/openai/v1",
        transcriptionModel: String = "whisper-large-v3",
        language: String? = nil,
        requestFormat: TranscriptionRequestFormat = .automatic,
        uploadFormat: AudioUploadEncoder.Format = .flac
    ) throws {
        self.apiKey = apiKey
        let normalizedBaseURL = try Self.normalizedBaseURL(from: baseURL)
        self.baseURL = normalizedBaseURL
        let trimmedModel = transcriptionModel.trimmingCharacters(in: .whitespacesAndNewlines)
        self.transcriptionModel = trimmedModel.isEmpty ? "whisper-large-v3" : trimmedModel
        let trimmedLanguage = language?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.language = (trimmedLanguage?.isEmpty == false) ? trimmedLanguage : nil
        self.requestFormat = requestFormat.resolved(forHost: normalizedBaseURL.host)
        self.uploadFormat = uploadFormat
    }

    static func responseFormat(forModel model: String) -> String {
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return modelsSupportingVerboseJSON.contains(normalizedModel) ? "verbose_json" : "json"
    }

    // Validate API key by hitting a lightweight endpoint
    static func validateAPIKey(_ key: String, baseURL: String = "https://api.groq.com/openai/v1") async -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let baseURL = try? normalizedBaseURL(from: baseURL) else { return false }

        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.timeoutInterval = 10
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")

        do {
            let (_, response) = try await LLMAPITransport.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return status == 200
        } catch {
            return false
        }
    }

    // Upload audio file, submit for transcription, poll until done, return text
    func transcribe(fileURL: URL) async throws -> String {
        guard !Task.isCancelled else {
            throw CancellationError()
        }

        let audioDurationSeconds = Self.audioDurationSeconds(of: fileURL)
        let timeoutSeconds = TranscriptionTimeoutBudget.seconds(
            baseSeconds: transcriptionTimeoutBaseSeconds,
            audioDurationSeconds: audioDurationSeconds
        )
        let timeoutReport = makeTimeoutReport(
            timeoutSeconds: timeoutSeconds,
            audioDurationSeconds: audioDurationSeconds,
            fileURL: fileURL
        )
        let raceState = TranscriptionTimeoutRaceState()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                raceState.setContinuation(continuation)

                let transcriptionTask = Task { [weak self] in
                    do {
                        guard let self else {
                            throw TranscriptionError.transcriptionFailed("Transcription service deallocated")
                        }
                        let result = try await self.transcribeAudio(
                            fileURL: fileURL,
                            timeoutSeconds: timeoutSeconds
                        )
                        raceState.finish(.success(result))
                    } catch {
                        raceState.finish(.failure(Self.transcriptionTimeoutErrorIfNeeded(
                            error,
                            report: timeoutReport
                        )))
                    }
                }

                let timeoutTask = Task {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                        raceState.finish(.failure(TranscriptionError.transcriptionTimedOut(timeoutReport)))
                    } catch is CancellationError {
                    } catch {
                        raceState.finish(.failure(error))
                    }
                }

                raceState.setTasks([transcriptionTask, timeoutTask])
            }
        } onCancel: {
            raceState.cancel()
        }
    }

    // Send audio file for transcription and return text
    private func transcribeAudio(fileURL: URL, timeoutSeconds: TimeInterval) async throws -> String {
        return try await transcribeAudioWithURLSession(fileURL: fileURL, timeoutSeconds: timeoutSeconds)
    }

    private func makeTimeoutReport(
        timeoutSeconds: TimeInterval,
        audioDurationSeconds: TimeInterval?,
        fileURL: URL
    ) -> TranscriptionTimeoutReport {
        let audioBytes = fileSizeBytes(for: fileURL)
        // Base64 inflates the body by a third, which matters on a slow uplink.
        let uploadBytes: Int64? = audioBytes > 0
            ? (requestFormat == .jsonBase64 ? Int64(Double(audioBytes) * 4 / 3) : audioBytes)
            : nil
        return TranscriptionTimeoutReport(
            timeoutSeconds: timeoutSeconds,
            audioDurationSeconds: audioDurationSeconds,
            uploadByteCount: uploadBytes,
            host: baseURL.host,
            usesJSONBase64: requestFormat == .jsonBase64,
            model: transcriptionModel,
            defaultsDomain: Bundle.main.bundleIdentifier
        )
    }

    private func transcribeAudioWithURLSession(
        fileURL: URL,
        timeoutSeconds: TimeInterval
    ) async throws -> String {
        let url = baseURL
            .appendingPathComponent("audio")
            .appendingPathComponent("transcriptions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        // Compress before upload. FLAC is lossless, so the provider still sees
        // the exact samples that were recorded; it just waits for ~2.3x fewer
        // bytes. Falls back to the original recording if anything goes wrong.
        let upload = AudioUploadEncoder.prepareUpload(
            fileURL: fileURL,
            preferredFormat: uploadFormat,
            audioDurationSeconds: Self.audioDurationSeconds(of: fileURL)
        )
        defer { upload.cleanUp() }

        let audioData = try Data(contentsOf: upload.fileURL)
        let fileName = upload.fileURL.lastPathComponent
        let body: Data

        switch requestFormat {
        case .multipart:
            let boundary = UUID().uuidString
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            body = TranscriptionRequestBody.multipart(
                audioData: audioData,
                fileName: fileName,
                model: transcriptionModel,
                responseFormat: transcriptionResponseFormat,
                language: language,
                boundary: boundary
            )
        case .jsonBase64:
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            body = try TranscriptionRequestBody.jsonBase64(
                audioData: audioData,
                fileName: fileName,
                model: transcriptionModel,
                language: language
            )
        }

        do {
            let (data, response) = try await LLMAPITransport.upload(for: request, from: body)
            return try validateTranscriptionResponse(
                data: data,
                response: response,
                fileURL: fileURL,
                audioDurationSeconds: Self.audioDurationSeconds(of: fileURL)
            )
        } catch {
            let nsError = error as NSError
            os_log(
                .error,
                log: transcriptionLog,
                "URLSession upload failed for %{public}@ (bytes=%{public}lld): domain=%{public}@ code=%ld desc=%{public}@",
                fileURL.lastPathComponent,
                fileSizeBytes(for: fileURL),
                nsError.domain,
                nsError.code,
                error.localizedDescription
            )
            throw error
        }
    }

    private func validateTranscriptionResponse(
        data: Data,
        response: URLResponse,
        fileURL: URL,
        audioDurationSeconds: TimeInterval?
    ) throws -> String {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.submissionFailed("No response from server")
        }

        guard httpResponse.statusCode == 200 else {
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            os_log(
                .error,
                log: transcriptionLog,
                "URLSession upload returned HTTP %ld for %{public}@ (bytes=%{public}lld) body=%{public}@",
                httpResponse.statusCode,
                fileURL.lastPathComponent,
                fileSizeBytes(for: fileURL),
                responseBody
            )
            throw TranscriptionError.submissionFailed(Self.friendlyHTTPMessage(
                status: httpResponse.statusCode,
                host: baseURL.host,
                audioDurationSeconds: audioDurationSeconds
            ))
        }

        return try parseTranscript(from: data)
    }
    private func fileSizeBytes(for fileURL: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? -1
    }

    /// Map a non-200 HTTP status into a one-line user-readable message.
    /// Used for transcription submission failures so the menu bar shows
    /// "Invalid API key for api.openai.com" instead of raw JSON.
    static func friendlyHTTPMessage(
        status: Int,
        host: String?,
        audioDurationSeconds: TimeInterval? = nil
    ) -> String {
        let provider = host ?? "the provider"
        switch status {
        case 401:
            return "Invalid API key for \(provider). Open Settings to fix it."
        case 403:
            return "Key lacks permission for this endpoint at \(provider) (HTTP 403). Check the key's scopes."
        case 404:
            return "Endpoint not found at \(provider) (HTTP 404). Base URL is likely wrong for this provider."
        case 413:
            return "Audio file too large for \(provider) (HTTP 413). Try a shorter recording."
        case 400:
            // A sub-second clip is the common cause and the old wording sent
            // users to check a model name and base URL that were both correct.
            if let audioDurationSeconds, audioDurationSeconds < Self.shortAudioWarningSeconds {
                return "\(provider) rejected the recording as too short (HTTP 400): only \(String(format: "%.1f", audioDurationSeconds))s of audio. Hold the shortcut until you have finished speaking."
            }
            return "\(provider) rejected the request (HTTP 400). Most often the transcription model name is not one this provider serves, or the audio format is unsupported. Check the Transcription Model and Base URL in Settings."
        case 429:
            return "Rate limit reached at \(provider) (HTTP 429). Wait a moment and try again."
        case 500..<600:
            return "Provider error at \(provider) (HTTP \(status)). Try again in a moment."
        default:
            return "Request failed at \(provider) (HTTP \(status))."
        }
    }

    /// Recordings below this are almost always a mistaken tap of the shortcut,
    /// and are what providers reject with HTTP 400.
    static let shortAudioWarningSeconds: TimeInterval = 1.0

    private static func transcriptionTimeoutErrorIfNeeded(
        _ error: Error,
        report: TranscriptionTimeoutReport
    ) -> Error {
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return TranscriptionError.transcriptionTimedOut(report)
        }
        return error
    }

    private static func normalizedBaseURL(from baseURL: String) throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TranscriptionError.invalidBaseURL("Provider URL is empty.")
        }

        guard var components = URLComponents(string: trimmed) else {
            throw TranscriptionError.invalidBaseURL("Provider URL is malformed.")
        }

        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw TranscriptionError.invalidBaseURL("Provider URL must use http or https.")
        }

        guard let host = components.host, !host.isEmpty else {
            throw TranscriptionError.invalidBaseURL("Provider URL must include a host.")
        }

        components.scheme = scheme
        if components.path == "/" {
            components.path = ""
        } else {
            components.path = components.path.replacingOccurrences(
                of: "/+$",
                with: "",
                options: .regularExpression
            )
        }

        guard let normalizedURL = components.url else {
            throw TranscriptionError.invalidBaseURL("Provider URL is malformed.")
        }

        return normalizedURL
    }

    private func parseTranscript(from data: Data) throws -> String {
        do {
            return try TranscriptionResponseParser.parse(data)
        } catch TranscriptionResponseParsingError.invalidResponse {
            throw TranscriptionError.pollFailed("Invalid response")
        }
    }
}

enum TranscriptionError: LocalizedError, ShortDisplayableError {
    case invalidBaseURL(String)
    case uploadFailed(String)
    case submissionFailed(String)
    case transcriptionFailed(String)
    case transcriptionTimedOut(TranscriptionTimeoutReport)
    case pollFailed(String)
    case audioPreparationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let msg): return "Invalid provider URL: \(msg)"
        case .uploadFailed(let msg): return "Upload failed: \(msg)"
        case .submissionFailed(let msg): return "Submission failed: \(msg)"
        case .transcriptionTimedOut(let report): return report.detailedMessage
        case .transcriptionFailed(let msg): return "Transcription failed: \(msg)"
        case .pollFailed(let msg): return "Polling failed: \(msg)"
        case .audioPreparationFailed(let msg): return "Audio preparation failed: \(msg)"
        }
    }

    /// The overlay and menu bar get one line; the full explanation stays in
    /// `errorDescription`, which is what the Run Log renders.
    var shortDisplayMessage: String {
        switch self {
        case .transcriptionTimedOut(let report):
            return report.shortMessage
        default:
            return errorDescription ?? "Transcription failed"
        }
    }
}

private final class TranscriptionTimeoutRaceState {
    private let lock = NSLock()
    private var didFinish = false
    private var continuation: CheckedContinuation<String, Error>?
    private var tasks: [Task<Void, Never>] = []

    func setContinuation(_ continuation: CheckedContinuation<String, Error>) {
        lock.lock()
        if didFinish {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }

        self.continuation = continuation
        lock.unlock()
    }

    func setTasks(_ tasks: [Task<Void, Never>]) {
        lock.lock()
        if didFinish {
            lock.unlock()
            tasks.forEach { $0.cancel() }
            return
        }

        self.tasks = tasks
        lock.unlock()
    }

    func finish(_ result: Result<String, Error>) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }

        didFinish = true
        let continuation = self.continuation
        self.continuation = nil
        let tasks = self.tasks
        self.tasks = []
        lock.unlock()

        tasks.forEach { $0.cancel() }

        switch result {
        case .success(let value):
            continuation?.resume(returning: value)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }
}

private struct PreparedUploadAudio {
    let fileURL: URL
    let deleteOnCleanup: Bool

    func cleanup() {
        guard deleteOnCleanup else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}
