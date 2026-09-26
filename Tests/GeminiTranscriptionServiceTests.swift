import Foundation

enum GeminiTranscriptionServiceTests {
    static func run() {
        testRequestBodyCarriesModelAudioAndMode()
        testRequestBodyOmitsEmptyVocabularyAndLanguages()
        testParseTranscriptReadsTrailingModelOutput()
        testParseTranscriptFallsBackToOutputs()
        testParseTranscriptRejectsEmptyFailedAndGarbage()
        testClassifyMapsStatusCodes()
        testClassifyReadsRetryDelay()
        testIsRetryable()
        testEngineKeyLocations()
    }

    // MARK: - Request body

    private static func requestJSON(
        audio: Data = Data("RIFF-fake-wav".utf8),
        mode: GeminiTranscriptionService.Mode = .verbatim,
        vocabulary: [String] = [],
        languages: [String] = []
    ) -> [String: Any] {
        do {
            let data = try GeminiTranscriptionService.requestBody(
                audioData: audio,
                mode: mode,
                vocabulary: vocabulary,
                languages: languages
            )
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                fail("Request body is not a JSON object")
            }
            return object
        } catch {
            fail("requestBody threw \(error)")
        }
    }

    private static func transcriptionConfig(in json: [String: Any]) -> [String: Any] {
        let generation = json["generation_config"] as? [String: Any]
        guard let config = generation?["transcription_config"] as? [String: Any] else {
            fail("Missing generation_config.transcription_config")
        }
        return config
    }

    private static func testRequestBodyCarriesModelAudioAndMode() {
        let audio = Data([0x52, 0x49, 0x46, 0x46, 0x00, 0xFF, 0x10])
        let json = requestJSON(
            audio: audio,
            vocabulary: ["Megaphone", "SwiftUI"],
            languages: ["en-US"]
        )

        expectEqual(json["model"] as? String, "gemini-3.5-transcribe", "Wrong model")
        expectEqual(json["store"] as? Bool, false, "Interactions must not be stored")

        guard let input = json["input"] as? [[String: Any]], input.count == 1 else {
            fail("Expected exactly one input content block")
        }
        expectEqual(input[0]["type"] as? String, "audio", "Input must be an audio block")
        expectEqual(input[0]["mime_type"] as? String, "audio/wav", "Wrong audio MIME type")
        let decoded = (input[0]["data"] as? String).flatMap { Data(base64Encoded: $0) }
        expectEqual(decoded, audio, "Audio must round-trip through base64")

        let config = transcriptionConfig(in: json)
        expectEqual(config["mode"] as? String, "verbatim", "Default mode must be verbatim")
        expectEqual(config["custom_vocabulary"] as? [String], ["Megaphone", "SwiftUI"],
                    "Vocabulary must be passed through")
        expectEqual(config["language_codes"] as? [String], ["en-US"], "Language must be passed through")

        let smart = transcriptionConfig(in: requestJSON(mode: .smart))
        expectEqual(smart["mode"] as? String, "smart", "Smart mode must be sent as \"smart\"")
    }

    private static func testRequestBodyOmitsEmptyVocabularyAndLanguages() {
        let config = transcriptionConfig(in: requestJSON(vocabulary: [], languages: []))
        expect(config["custom_vocabulary"] == nil, "Empty vocabulary must omit the field")
        expect(config["language_codes"] == nil, "Auto-detect must omit language_codes")

        let blanks = transcriptionConfig(in: requestJSON(vocabulary: [""], languages: [""]))
        expect(blanks["custom_vocabulary"] == nil, "Blank vocabulary terms must be dropped")
        expect(blanks["language_codes"] == nil, "Blank language codes must be dropped")
    }

    // MARK: - Response parsing

    private static func testParseTranscriptReadsTrailingModelOutput() {
        let body = #"""
        {
          "id": "abc",
          "status": "completed",
          "steps": [
            {"type": "user_input", "content": [{"type": "text", "text": "ignored"}]},
            {"type": "model_output", "content": [{"type": "text", "text": "stale"}]},
            {"type": "model_output", "content": [
              {"type": "text", "text": "Hello "},
              {"type": "text", "text": "world"}
            ]}
          ]
        }
        """#
        expectEqual(try? GeminiTranscriptionService.parseTranscript(from: Data(body.utf8)),
                    "Hello world", "Must join text parts of the last model_output step")
    }

    private static func testParseTranscriptFallsBackToOutputs() {
        let body = #"{"status": "completed", "outputs": [{"type": "text", "text": "from outputs"}]}"#
        expectEqual(try? GeminiTranscriptionService.parseTranscript(from: Data(body.utf8)),
                    "from outputs", "Must accept the older top-level outputs shape")
    }

    private static func testParseTranscriptRejectsEmptyFailedAndGarbage() {
        expectThrows(.malformedResponse, from: Data("not json".utf8))
        expectThrows(.malformedResponse, from: Data(#"{"status": "completed"}"#.utf8))
        expectThrows(
            .emptyTranscript,
            from: Data(#"{"steps": [{"type": "model_output", "content": [{"type": "text", "text": "  "}]}]}"#.utf8)
        )
        expectThrows(
            .interactionFailed("audio unreadable"),
            from: Data(#"{"status": "failed", "steps": [], "errors": [{"message": "audio unreadable"}]}"#.utf8)
        )
    }

    // MARK: - Status classification

    /// Captured from the live endpoint: a bad key is a 400 whose error
    /// envelope arrives wrapped in a one-element array.
    private static let invalidKeyBody = #"""
    [{
      "error": {
        "code": 400,
        "message": "API key not valid. Please pass a valid API key.",
        "status": "INVALID_ARGUMENT",
        "details": [
          {
            "@type": "type.googleapis.com/google.rpc.ErrorInfo",
            "reason": "API_KEY_INVALID",
            "domain": "googleapis.com",
            "metadata": {"service": "generativelanguage.googleapis.com"}
          }
        ]
      }
    }]
    """#

    private static func classify(_ status: Int, body: String = "", headers: [AnyHashable: Any] = [:]) -> String {
        let error = GeminiTranscriptionService.classify(status: status, headers: headers, body: Data(body.utf8))
        return error.map { "\($0)" } ?? "nil"
    }

    private static func testClassifyMapsStatusCodes() {
        expectEqual(classify(200), "nil", "200 is success")
        expectEqual(classify(400, body: invalidKeyBody), "unauthorized",
                    "API_KEY_INVALID must map to unauthorized, not badRequest")
        expectEqual(
            classify(400, body: #"{"error": {"code": 400, "message": "Unsupported audio"}}"#),
            "badRequest(\"Unsupported audio\")",
            "Other 400s must carry the server message"
        )
        expectEqual(classify(401), "unauthorized", "401 is unauthorized")
        expectEqual(classify(403), "unauthorized", "403 is unauthorized")
        expectEqual(classify(404), "badRequest(\"status 404\")", "404 without a body is badRequest")
        expectEqual(classify(413), "fileTooLarge(bytes: 0)", "413 is fileTooLarge")
        expectEqual(classify(503), "serverError(status: 503)", "503 is serverError")
    }

    private static func testClassifyReadsRetryDelay() {
        let quotaBody = #"""
        {"error": {"code": 429, "message": "Quota exceeded", "status": "RESOURCE_EXHAUSTED",
          "details": [{"@type": "type.googleapis.com/google.rpc.RetryInfo", "retryDelay": "7s"}]}}
        """#
        expectEqual(classify(429, body: quotaBody), "rateLimited(retryAfter: Optional(7.0))",
                    "RetryInfo.retryDelay must be honoured")
        expectEqual(classify(429, headers: ["Retry-After": "3"]), "rateLimited(retryAfter: Optional(3.0))",
                    "Retry-After header is the fallback")
        expectEqual(classify(429), "rateLimited(retryAfter: nil)", "No hint means no delay")

        expectEqual(GeminiTranscriptionService.durationSeconds("0.5s"), 0.5, "Fractional durations parse")
        expect(GeminiTranscriptionService.durationSeconds("7") == nil, "Durations need the s suffix")
    }

    private static func testIsRetryable() {
        let terminal: [GeminiTranscriptionError] = [
            .missingAPIKey, .unauthorized, .badRequest("x"), .fileTooLarge(bytes: 1),
            .interactionFailed("x"), .emptyTranscript, .malformedResponse
        ]
        for error in terminal {
            expect(!GeminiTranscriptionService.isRetryable(error), "\(error) must not be retried")
        }

        let transient: [GeminiTranscriptionError] = [
            .rateLimited(retryAfter: nil), .serverError(status: 500), .serverError(status: 503)
        ]
        for error in transient {
            expect(GeminiTranscriptionService.isRetryable(error), "\(error) must be retried")
        }

        expect(GeminiTranscriptionService.isRetryable(URLError(.timedOut)), "Timeouts must be retried")
        expect(!GeminiTranscriptionService.isRetryable(URLError(.unsupportedURL)),
               "Programming errors must not be retried")
    }

    // MARK: - Engine metadata

    private static func testEngineKeyLocations() {
        expectEqual(TranscriptionEngine.gemini.apiKeyFilePath, "~/.config/megaphone/gemini-key",
                    "Gemini key file path")
        expectEqual(TranscriptionEngine.gemini.apiKeyEnvironmentVariables, ["GEMINI_API_KEY"],
                    "Gemini env var")
        expectEqual(TranscriptionEngine.openAI.apiKeyFilePath, "~/.config/megaphone/openai-key",
                    "OpenAI key file path must not move")
        expect(TranscriptionEngine.appleOnDevice.apiKeyFilePath == nil, "Apple needs no key")
        expect(!TranscriptionEngine.appleOnDevice.isCloud, "Apple is on-device")
        expect(TranscriptionEngine.gemini.isCloud && TranscriptionEngine.openAI.isCloud,
               "Both uploads are cloud engines")
        expect(APIKeyStore.currentKey(for: .appleOnDevice) == nil, "Apple never resolves a key")
    }

    // MARK: - Assertions

    private static func expectThrows(
        _ expected: GeminiTranscriptionError,
        from data: Data,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        do {
            let transcript = try GeminiTranscriptionService.parseTranscript(from: data)
            fail("Expected \(expected) but got \(transcript.debugDescription)", file: file, line: line)
        } catch let error as GeminiTranscriptionError {
            expect("\(error)" == "\(expected)",
                   "Expected \(expected) but got \(error)", file: file, line: line)
        } catch {
            fail("Expected \(expected) but got \(error)", file: file, line: line)
        }
    }

    private static func expectEqual<T: Equatable>(
        _ actual: T?,
        _ expected: T,
        _ message: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        expect(actual == expected, "\(message) (got \(String(describing: actual)))",
               file: file, line: line)
    }

    private static func expect(
        _ condition: Bool,
        _ message: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        if !condition {
            fail(message, file: file, line: line)
        }
    }

    private static func fail(
        _ message: String,
        file: StaticString = #file,
        line: UInt = #line
    ) -> Never {
        fatalError("GeminiTranscriptionServiceTests: \(message)", file: file, line: line)
    }
}
