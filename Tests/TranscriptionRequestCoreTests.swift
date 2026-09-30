import Foundation

enum TranscriptionRequestCoreTests {
    static func run() {
        testAutomaticFormatFollowsHost()
        testExplicitFormatOverridesHost()
        testStoredRawValuesNormalize()
        testZenMuxDetection()
        testAudioFormatMapping()
        testMultipartBodyShape()
        testJSONBase64BodyShape()
    }

    private static func testAutomaticFormatFollowsHost() {
        TestSupport.expectEqual(
            TranscriptionRequestFormat.automatic.resolved(forHost: "api.groq.com"),
            .multipart
        )
        TestSupport.expectEqual(
            TranscriptionRequestFormat.automatic.resolved(forHost: "api.openai.com"),
            .multipart
        )
        TestSupport.expectEqual(
            TranscriptionRequestFormat.automatic.resolved(forHost: nil),
            .multipart
        )
        TestSupport.expectEqual(
            TranscriptionRequestFormat.automatic.resolved(forHost: "zenmux.ai"),
            .jsonBase64
        )
        TestSupport.expectEqual(
            TranscriptionRequestFormat.automatic.resolved(forHost: "ZenMux.AI"),
            .jsonBase64
        )
        TestSupport.expectEqual(
            TranscriptionRequestFormat.automatic.resolved(forHost: "api.zenmux.ai"),
            .jsonBase64
        )
        // A host that merely ends in the same letters is a different provider.
        TestSupport.expectEqual(
            TranscriptionRequestFormat.automatic.resolved(forHost: "notzenmux.ai"),
            .multipart
        )
    }

    private static func testExplicitFormatOverridesHost() {
        TestSupport.expectEqual(
            TranscriptionRequestFormat.multipart.resolved(forHost: "zenmux.ai"),
            .multipart
        )
        TestSupport.expectEqual(
            TranscriptionRequestFormat.jsonBase64.resolved(forHost: "api.groq.com"),
            .jsonBase64
        )
    }

    private static func testStoredRawValuesNormalize() {
        TestSupport.expectEqual(TranscriptionRequestFormat.normalized(nil), .automatic)
        TestSupport.expectEqual(TranscriptionRequestFormat.normalized(""), .automatic)
        TestSupport.expectEqual(TranscriptionRequestFormat.normalized("nonsense"), .automatic)
        TestSupport.expectEqual(TranscriptionRequestFormat.normalized(" Multipart "), .multipart)
        TestSupport.expectEqual(TranscriptionRequestFormat.normalized("json_base64"), .jsonBase64)
    }

    private static func testZenMuxDetection() {
        TestSupport.expect(
            TranscriptionProvider.isZenMux(baseURL: "https://zenmux.ai/api/v1"),
            "ZenMux base URL should be detected"
        )
        TestSupport.expect(
            TranscriptionProvider.isZenMux(baseURL: " https://ZenMux.ai/api/v1/ "),
            "Detection should ignore case and surrounding whitespace"
        )
        TestSupport.expect(
            !TranscriptionProvider.isZenMux(baseURL: "https://api.groq.com/openai/v1"),
            "Groq base URL should not be detected as ZenMux"
        )
        TestSupport.expect(
            !TranscriptionProvider.isZenMux(baseURL: ""),
            "An empty base URL should not be detected as ZenMux"
        )
    }

    private static func testAudioFormatMapping() {
        TestSupport.expectEqual(TranscriptionRequestBody.audioFormat(forFileName: "clip.wav"), "wav")
        TestSupport.expectEqual(TranscriptionRequestBody.audioFormat(forFileName: "clip.MP3"), "mp3")
        TestSupport.expectEqual(TranscriptionRequestBody.audioFormat(forFileName: "clip.m4a"), "m4a")
        TestSupport.expectEqual(TranscriptionRequestBody.audioFormat(forFileName: "clip.mp4"), "m4a")
        // ZFlow records WAV, so an unrecognized extension falls back to it.
        TestSupport.expectEqual(TranscriptionRequestBody.audioFormat(forFileName: "clip.bin"), "wav")
        TestSupport.expectEqual(TranscriptionRequestBody.audioFormat(forFileName: "clip"), "wav")

        TestSupport.expectEqual(TranscriptionRequestBody.contentType(forFileName: "clip.wav"), "audio/wav")
        TestSupport.expectEqual(TranscriptionRequestBody.contentType(forFileName: "clip.mp3"), "audio/mpeg")
        TestSupport.expectEqual(TranscriptionRequestBody.contentType(forFileName: "clip.m4a"), "audio/mp4")
    }

    private static func testMultipartBodyShape() {
        let audioData = Data([0x01, 0x02, 0x03])
        let body = TranscriptionRequestBody.multipart(
            audioData: audioData,
            fileName: "sample.wav",
            model: "whisper-large-v3",
            responseFormat: "verbose_json",
            language: "fr",
            boundary: "TESTBOUNDARY"
        )
        let text = String(decoding: body, as: UTF8.self)

        TestSupport.expect(text.contains("--TESTBOUNDARY\r\n"), "Body should open each part with the boundary")
        TestSupport.expect(text.contains("name=\"model\"\r\n\r\nwhisper-large-v3"), "Body should carry the model")
        TestSupport.expect(
            text.contains("name=\"response_format\"\r\n\r\nverbose_json"),
            "Body should carry the response format"
        )
        TestSupport.expect(text.contains("name=\"language\"\r\n\r\nfr"), "Body should carry the language")
        TestSupport.expect(
            text.contains("name=\"file\"; filename=\"sample.wav\""),
            "Body should upload the recording under the file field"
        )
        TestSupport.expect(text.contains("Content-Type: audio/wav"), "Body should declare the audio content type")
        TestSupport.expect(text.hasSuffix("--TESTBOUNDARY--\r\n"), "Body should close with the terminating boundary")

        let withoutLanguage = TranscriptionRequestBody.multipart(
            audioData: audioData,
            fileName: "sample.wav",
            model: "whisper-large-v3",
            responseFormat: "json",
            language: nil,
            boundary: "TESTBOUNDARY"
        )
        TestSupport.expect(
            !String(decoding: withoutLanguage, as: UTF8.self).contains("name=\"language\""),
            "An absent language should not be sent"
        )
    }

    private static func testJSONBase64BodyShape() {
        let audioData = Data([0x01, 0x02, 0x03])
        guard let body = try? TranscriptionRequestBody.jsonBase64(
            audioData: audioData,
            fileName: "sample.wav",
            model: "qwen/qwen3-asr-flash",
            language: "fr"
        ),
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            TestSupport.expect(false, "JSON body should encode")
            return
        }

        TestSupport.expectEqual(json["model"] as? String, "qwen/qwen3-asr-flash")
        TestSupport.expectEqual(json["language"] as? String, "fr")
        // ZenMux does not accept response_format and always answers with text.
        TestSupport.expect(json["response_format"] == nil, "JSON body should omit response_format")

        let inputAudio = json["input_audio"] as? [String: Any]
        TestSupport.expectEqual(inputAudio?["format"] as? String, "wav")
        // Raw base64, not a data URI.
        TestSupport.expectEqual(inputAudio?["data"] as? String, audioData.base64EncodedString())

        guard let withoutLanguage = try? TranscriptionRequestBody.jsonBase64(
            audioData: audioData,
            fileName: "sample.m4a",
            model: "qwen/qwen3-asr-flash",
            language: nil
        ),
            let plainJSON = try? JSONSerialization.jsonObject(with: withoutLanguage) as? [String: Any] else {
            TestSupport.expect(false, "JSON body should encode without a language")
            return
        }

        TestSupport.expect(plainJSON["language"] == nil, "An absent language should not be sent")
        TestSupport.expectEqual((plainJSON["input_audio"] as? [String: Any])?["format"] as? String, "m4a")
    }
}
